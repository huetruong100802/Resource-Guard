# rg-watcher.ps1 - watcher nền của Resource Guard (P1.5): CHỈ GIÁM SÁT, KHÔNG kill/xoá bất cứ thứ gì.
# Mỗi chu kỳ: lấy snapshot -> ghi metrics -> cập nhật trạng thái (có hysteresis) -> toast khi đổi trạng thái
# -> ghi 'would-act' (việc mà chế độ tự động SẼ làm) -> vẽ state\status.html (mở được dù máy lag, không cần server).
#   rg-watcher.ps1                 # chạy vòng lặp (dùng cho Scheduled Task)
#   rg-watcher.ps1 -Once [-Json]   # đúng 1 chu kỳ rồi thoát (test / kiểm tra nhanh)
[CmdletBinding()]
param(
    [int]$IntervalSec = 0,           # 0 = lấy từ state\ui-settings.json (mặc định 15)
    [switch]$Once, [switch]$NoToast, [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

$script:ToastCooldownMin = 10    # không toast lặp lại cùng một trạng thái trong khoảng này
$script:LowerHoldSec = 45        # hạ trạng thái chỉ khi thấp hơn liên tục ngần này giây (hysteresis, tính theo thời gian)
$script:KeepMetricsDays = 14
$script:TableRefreshSec = 30     # bảng process (tốn nhất) làm mới tối đa mỗi ngần này giây
$script:DefaultIntervalSec = 15; $script:MinIntervalSec = 2; $script:MaxIntervalSec = 300
$script:RgTableCache = $null; $script:RgTableAt = [datetime]::MinValue; $script:RgLastReasons = @()
$script:Palette = @{ Normal = '#2e9e5b'; Caution = '#d9a400'; Restricted = '#e07b00'; Critical = '#d6342c' }

function Get-RgWatcherStatePath { return (Join-Path (Initialize-RgHome) 'state\watcher.json') }

function Read-RgWatcherState {
    $p = Get-RgWatcherStatePath
    if (Test-Path -LiteralPath $p) {
        try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ state = 'Normal'; lowerCount = 0; lastToastState = ''; lastToastUtc = ''; lastOrphanKey = '' }
}

function Write-RgWatcherState($S) {
    $p = Get-RgWatcherStatePath
    $tmp = "$p.tmp"
    Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject $S -Depth 4) -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

# Tăng: áp dụng ngay. Giảm: cần LowerTicksNeeded chu kỳ liên tiếp. Thuần hàm, có test.
function Get-RgEffectiveState([string]$Prev, [int]$LowerCount, [string]$Raw, [int]$Needed = 3) {
    $pi = [array]::IndexOf($script:RgStates, $Prev)
    $ri = [array]::IndexOf($script:RgStates, $Raw)
    if ($ri -ge $pi) { return [pscustomobject]@{ state = $Raw; lowerCount = 0 } }
    $n = $LowerCount + 1
    if ($n -ge $Needed) { return [pscustomobject]@{ state = $Raw; lowerCount = 0 } }
    return [pscustomobject]@{ state = $Prev; lowerCount = $n }
}

# ---------- Cài đặt người dùng chỉnh qua UI (chu kỳ lấy mẫu) ----------

function Get-RgSettingsPath { return (Join-Path (Initialize-RgHome) 'state\ui-settings.json') }

function Get-RgSettings {
    $s = [pscustomobject]@{ intervalSec = $script:DefaultIntervalSec }
    $p = Get-RgSettingsPath
    if (Test-Path -LiteralPath $p) {
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = [int]$j.intervalSec
            if ($v -ge $script:MinIntervalSec -and $v -le $script:MaxIntervalSec) { $s.intervalSec = $v }
        } catch { }
    }
    return $s
}

function Set-RgSettings([int]$IntervalSec) {
    if ($IntervalSec -lt $script:MinIntervalSec -or $IntervalSec -gt $script:MaxIntervalSec) {
        throw "intervalSec phải trong khoảng $($script:MinIntervalSec)-$($script:MaxIntervalSec) giây."
    }
    $p = Get-RgSettingsPath
    $tmp = "$p.tmp"
    Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject ([ordered]@{ intervalSec = $IntervalSec }) -Compress) -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $p -Force
    Write-RgLog 'settings-change' ([ordered]@{ intervalSec = $IntervalSec })
    return (Get-RgSettings)
}

function Send-RgToast([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = { param($s) [Security.SecurityElement]::Escape($s) }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$(& $esc $Title)</text><text>$(& $esc $Body)</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
        return $true
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.ShowBalloonTip(8000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Milliseconds 300
        $ni.Dispose()
        return $true
    } catch { return $false }
}

# ---------- Chữ cho người dùng: tên trạng thái + nội dung toast dựng từ SỐ LIỆU có cấu trúc (không dán `reasons` tiếng Anh) ----------

function Get-RgStateVi([string]$State) {
    switch ($State) { 'Normal' { return 'Ổn' } 'Caution' { return 'Cần chú ý' } 'Restricted' { return 'Hạn chế' } 'Critical' { return 'Nguy cấp' } default { return $State } }
}

function Format-RgGBVi($Gb) { return ([math]::Round([double]$Gb, 1)).ToString('0.0', [Globalization.CultureInfo]::GetCultureInfo('vi-VN')) }

# { title; body } cho toast khi trạng thái ĐỔI. $Eff = trạng thái hiệu lực; $Budget = Get-RgBudget; $Snap = snapshot (có drives).
# Chọn nguồn áp lực nặng nhất (ổ > RAM > commit khi bằng nhau) và nói bằng một câu kèm việc nên làm tiếp.
function Get-RgToastText([string]$Eff, [bool]$Worse, $Budget, $Snap, $Cfg) {
    if (-not $Worse) {
        return [pscustomobject]@{ title = 'Resource Guard: máy đã ổn'; body = 'Các chỉ số đã trở lại bình thường. Không cần làm gì thêm.' }
    }
    $rank = @{ 'Normal' = 0; 'Caution' = 1; 'Restricted' = 2; 'Critical' = 3 }
    $cands = @()
    foreach ($d in @($Snap.drives | Where-Object { $_ })) {
        $s = Get-RgDiskState $d.freeGB $Cfg ([string]$d.drive)
        if ($rank[$s] -gt 0) { $cands += [pscustomobject]@{ sev = $rank[$s]; pri = 0; text = "Ổ $($d.drive) còn $(Format-RgGBVi $d.freeGB) GB. Mở Resource Guard để xem kế hoạch dọn." } }
    }
    if (@($Snap.drives | Where-Object { $_ }).Count -eq 0 -and $null -ne $Snap.diskFreeGB) {
        $s = Get-RgDiskState $Snap.diskFreeGB $Cfg ([string]$Snap.diskDrive)
        if ($rank[$s] -gt 0) { $cands += [pscustomobject]@{ sev = $rank[$s]; pri = 0; text = "Ổ $($Snap.diskDrive) còn $(Format-RgGBVi $Snap.diskFreeGB) GB. Mở Resource Guard để xem kế hoạch dọn." } }
    }
    $rs = Get-RgRamState ([double]$Snap.availRamGB) $Cfg
    if ($rank[$rs] -gt 0) { $cands += [pscustomobject]@{ sev = $rank[$rs]; pri = 1; text = "RAM trống còn $(Format-RgGBVi $Snap.availRamGB) GB. Mở Resource Guard để xem tiến trình đang chiếm nhiều." } }
    $cs = Get-RgCommitState ([double]$Snap.commitPct) $Cfg
    if ($rank[$cs] -gt 0) { $cands += [pscustomobject]@{ sev = $rank[$cs]; pri = 2; text = "Bộ nhớ cam kết đã dùng $([math]::Round([double]$Snap.commitPct))%. Mở Resource Guard để xem chi tiết." } }
    $top = @($cands | Sort-Object @{ Expression = { $_.sev }; Descending = $true }, @{ Expression = { $_.pri } }) | Select-Object -First 1
    $body = if ($top) { $top.text } else { "Máy đang ở mức $(Get-RgStateVi $Eff). Mở Resource Guard để xem chi tiết." }
    return [pscustomobject]@{ title = "Resource Guard: $(Get-RgStateVi $Eff)"; body = $body }
}

# ---------- Thiết lập lần đầu (GET/POST /api/setup) ----------

$script:RgRepoRoot = Split-Path $PSScriptRoot -Parent
function Get-RgSetupFilePath { return (Join-Path (Initialize-RgHome) 'state\setup.json') }

# $Probe: scriptblock cho test thay cho việc dò Scheduled Task / lối tắt thật: { @{ autostart = $bool; shortcut = $bool } }.
function Get-RgSetupInfo($Probe = $null) {
    $a = $false; $s = $false
    if ($Probe) { $p = & $Probe; $a = [bool]$p.autostart; $s = [bool]$p.shortcut }
    else { . (Join-Path $PSScriptRoot 'rg-setup.ps1'); $a = Test-RgTaskInstalled; $s = Test-RgShortcutExists }
    return [ordered]@{
        autostart = $a; shortcut = $s; pinConfigured = [bool](Test-RgPinConfigured); mode = [string](Get-RgPolicy).mode
        firstRun = -not (Test-Path -LiteralPath (Get-RgSetupFilePath))
    }
}

# Body: { autostart?: bool, shortcut?: bool, firstRunDone?: true }. Chỉ nhận đúng kiểu bool; khoá lạ bị bỏ qua. PIN KHÔNG đặt qua đây (chỉ console).
# $Effects: { autostart = {param($on)}; shortcut = {param($on)} } cho test; mặc định gọi rg-setup.ps1 (cùng logic `rg autostart|shortcut`).
# Trả { ok; error; info }. Không ném lỗi.
function Invoke-RgSetupPost($Body, $Effects = $null, $Probe = $null) {
    $res = [ordered]@{ ok = $false; error = ''; info = $null }
    try {
        if ($null -eq $Body) { $res.error = 'Thiếu nội dung yêu cầu.'; return $res }
        $has = { param($n) [bool]$Body.PSObject.Properties[$n] }
        foreach ($n in 'autostart', 'shortcut') {
            if ((& $has $n) -and $Body.$n -isnot [bool]) { $res.error = "'$n' phải là true hoặc false."; return $res }
        }
        if ((& $has 'firstRunDone') -and $Body.firstRunDone -isnot [bool]) { $res.error = "'firstRunDone' phải là true."; return $res }
        if ($null -eq $Effects) {
            . (Join-Path $PSScriptRoot 'rg-setup.ps1')
            $root = $script:RgRepoRoot
            $Effects = @{ autostart = { param($on) [void](Set-RgAutostart $on $root -NoStart) }; shortcut = { param($on) [void](Set-RgShortcut $on $root) } }
        }
        $done = [ordered]@{}
        if (& $has 'autostart') { & $Effects.autostart ([bool]$Body.autostart); $done['autostart'] = [bool]$Body.autostart }
        if (& $has 'shortcut') { & $Effects.shortcut ([bool]$Body.shortcut); $done['shortcut'] = [bool]$Body.shortcut }
        if ((& $has 'firstRunDone') -and [bool]$Body.firstRunDone) {
            Write-RgFileAtomic (Get-RgSetupFilePath) (ConvertTo-Json -InputObject ([ordered]@{ firstRunDone = $true; doneUtc = (Get-Date).ToUniversalTime().ToString('o') }) -Compress)
            $done['firstRunDone'] = $true
        }
        if ($done.Count -gt 0) { Write-RgLog 'setup-change' $done }
        $res.ok = $true
        $res.info = Get-RgSetupInfo $Probe
    } catch { $res.error = 'Không áp dụng được thiết lập: ' + [string]$_.Exception.Message }
    return $res
}

function Remove-RgOldMetrics {
    $dir = Join-Path (Initialize-RgHome) 'state'
    $limit = (Get-Date).AddDays(-$script:KeepMetricsDays)
    Get-ChildItem -LiteralPath $dir -Filter 'metrics-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Read-RgMetricsTail([int]$Max = 240) {
    $dir = Join-Path (Initialize-RgHome) 'state'
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'metrics-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 3)
    $lines = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $chunk = @(Get-Content -LiteralPath $f.FullName -Tail $Max -Encoding UTF8)
        [array]::Reverse($chunk)
        foreach ($l in $chunk) { [void]$lines.Add($l) }
        if ($lines.Count -ge $Max) { break }
    }
    $rows = @()
    foreach ($l in @($lines | Select-Object -First $Max)) { try { $rows += ConvertFrom-Json $l } catch { } }
    [array]::Reverse($rows)
    return $rows
}

# Gộp bảng tiến trình theo TÊN: top 12 theo RAM hợp với top 8 theo CPU -> [{ name, n, cpu, ramMB }].
# Ghi vào mỗi bản ghi metrics (trường procTop) để dựng lịch sử theo tiến trình mà không phải lấy mẫu thêm.
function Get-RgProcTop($Procs, [int]$TopRam = 12, [int]$TopCpu = 8) {
    $g = @{}
    foreach ($p in @($Procs)) {
        $n = [string]$p.name
        if (-not $n) { continue }
        if (-not $g.ContainsKey($n)) { $g[$n] = @{ name = $n; n = 0; cpu = 0.0; ramMB = 0.0 } }
        $e = $g[$n]; $e.n++; $e.cpu += [double]$p.cpu; $e.ramMB += [double]$p.ramMB
    }
    $all = @($g.Values | ForEach-Object { [pscustomobject]@{ name = $_.name; n = [int]$_.n; cpu = [math]::Round($_.cpu, 1); ramMB = [int][math]::Round($_.ramMB) } })
    $byRam = @($all | Sort-Object ramMB -Descending | Select-Object -First $TopRam)
    $byCpu = @($all | Where-Object { $_.cpu -gt 0 } | Sort-Object cpu -Descending | Select-Object -First $TopCpu)
    $seen = @{}; $out = @()
    foreach ($e in ($byRam + $byCpu)) { if (-not $seen.ContainsKey($e.name)) { $seen[$e.name] = $true; $out += $e } }
    return @($out)
}

# Lịch sử CPU/RAM của MỘT nhóm tiến trình (theo tên) trong $Minutes phút gần nhất, từ procTop trong state\metrics-*.jsonl.
# Điểm thiếu (tiến trình không nằm trong top lúc đó) bị bỏ, KHÔNG nội suy. Tối đa $MaxPoints điểm (lấy thưa đều).
# Đọc từng dòng, so sánh ts dạng chuỗi trước khi parse JSON nên 24 giờ vẫn nhanh.
function Get-RgProcHistory([string]$Name, [int]$Minutes = 60, $Now = $null, [int]$MaxPoints = 720) {
    $Name = ([string]$Name).ToLowerInvariant()
    if ($Name -notmatch '^[a-z0-9._ -]{1,64}$') { throw 'Tên tiến trình không hợp lệ.' }
    if ($Minutes -lt 1) { $Minutes = 60 }
    if ($Minutes -gt 1440) { $Minutes = 1440 }
    if ($null -eq $Now) { $Now = Get-Date }
    $cutoff = ([datetime]$Now).AddMinutes(-$Minutes).ToString('yyyy-MM-dd HH:mm:ss')
    $dir = Join-Path (Initialize-RgHome) 'state'
    $needle = '"name":"' + $Name + '"'
    $points = New-Object System.Collections.ArrayList
    $lastLine = $null
    for ($d = ([datetime]$Now).AddMinutes(-$Minutes).Date; $d -le ([datetime]$Now).Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ('metrics-{0}.jsonl' -f $d.ToString('yyyyMMdd'))
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $fs = $null; $sr = $null
        try {
            $fs = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            while ($null -ne ($line = $sr.ReadLine())) {
                $i = $line.IndexOf('"ts":"')
                if ($i -lt 0 -or $line.Length -lt $i + 6 + 19) { continue }
                $ts = $line.Substring($i + 6, 19)
                if ([string]::CompareOrdinal($ts, $cutoff) -lt 0) { continue }
                $lastLine = $line
                if ($line.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { continue }
                try {
                    $rec = ConvertFrom-Json $line
                    foreach ($e in @($rec.procTop)) {
                        if ([string]$e.name -eq $Name) { [void]$points.Add([pscustomobject]@{ ts = [string]$rec.ts; cpu = [double]$e.cpu; ramMB = [double]$e.ramMB; n = [int]$e.n }); break }
                    }
                } catch { }
            }
        } finally { if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() } }
    }
    $total = 0
    if ($lastLine) { try { $total = [int][math]::Round([double](ConvertFrom-Json $lastLine).totalRamGB * 1024) } catch { } }
    $pts = @($points)
    if ($pts.Count -gt $MaxPoints) {
        $stride = [math]::Ceiling($pts.Count / $MaxPoints)
        $pts = @(for ($k = 0; $k -lt $pts.Count; $k += $stride) { $pts[$k] })
    }
    return [ordered]@{ name = $Name; totalRamMB = $total; points = $pts }
}

function New-RgSparkline($Values, [string]$Color, [double]$Min, [double]$Max) {
    $w = 560; $h = 70
    $v = @($Values | Where-Object { $null -ne $_ })
    if ($v.Count -lt 2) { return "<svg viewBox='0 0 $w $h' class='spark'></svg>" }
    if ($Max -le $Min) { $Max = $Min + 1 }
    $pts = for ($i = 0; $i -lt $v.Count; $i++) {
        $x = [math]::Round($i * $w / ($v.Count - 1), 1)
        $y = [math]::Round($h - 4 - (([math]::Min([math]::Max([double]$v[$i], $Min), $Max) - $Min) / ($Max - $Min)) * ($h - 8), 1)
        "$x,$y"
    }
    return "<svg viewBox='0 0 $w $h' class='spark' preserveAspectRatio='none'><polyline fill='none' stroke='$Color' stroke-width='2' points='$($pts -join ' ')'/></svg>"
}

function Write-RgStatusHtml($Rec, $Budget, $Eff) {
    $rows = @(Read-RgMetricsTail 240)
    $col = $script:Palette[$Eff]
    $ram = New-RgSparkline @($rows | ForEach-Object { $_.availRamGB }) $col 0 ([double]$Rec.totalRamGB)
    $disk = New-RgSparkline @($rows | ForEach-Object { $_.diskFreeGB }) '#3b7dd8' 0 ([math]::Max(1, (@($rows | ForEach-Object { $_.diskFreeGB } | Measure-Object -Maximum).Maximum)))
    $commit = New-RgSparkline @($rows | ForEach-Object { $_.commitPct }) '#8a5cd6' 0 100
    $top = ($Rec.top | ForEach-Object { "<tr><td>$([Net.WebUtility]::HtmlEncode($_.name))</td><td class='r'>$($_.ramMB) MB</td></tr>" }) -join ''
    $reasons = ($Budget.reasons | ForEach-Object { "<li>$([Net.WebUtility]::HtmlEncode([string]$_))</li>" }) -join ''
    if (-not $reasons) { $reasons = '<li>Mọi chỉ số trong ngưỡng bình thường.</li>' }
    $orph = if ($Rec.ledgerOrphans -gt 0) { "<p class='warn'>$($Rec.ledgerOrphans) tiến trình mồ côi trong ledger (chế độ giám sát: chưa tự xử lý).</p>" } else { '' }
    $html = @"
<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30"><title>Resource Guard</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1c2230;--mut:#667085;--line:#e3e6eb}
@media (prefers-color-scheme:dark){:root{--bg:#12151c;--card:#1b2029;--fg:#e8ebf2;--mut:#98a2b3;--line:#2a313d}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,Segoe UI,sans-serif}
.wrap{max-width:900px;margin:0 auto}
.badge{display:inline-block;padding:4px 14px;border-radius:999px;color:#fff;font-weight:600;background:$col}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin:14px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.k{color:var(--mut);font-size:12px}.v{font-size:22px;font-weight:600}
.spark{width:100%;height:70px;display:block}
table{width:100%;border-collapse:collapse}td{padding:3px 0;border-bottom:1px solid var(--line)}.r{text-align:right}
.warn{color:#d6342c}.mut{color:var(--mut);font-size:12px}
</style></head><body><div class="wrap">
<h2>Resource Guard <span class="badge">$Eff</span></h2>
<div class="mut">Cập nhật $($Rec.ts) · chế độ GIÁM SÁT (không tự kill/xoá) · tự làm mới mỗi 30 giây</div>
<div class="grid">
<div class="card"><div class="k">RAM trống</div><div class="v">$($Rec.availRamGB) / $($Rec.totalRamGB) GB</div></div>
<div class="card"><div class="k">Commit</div><div class="v">$($Rec.commitPct)%</div></div>
<div class="card"><div class="k">CPU</div><div class="v">$($Rec.cpuPct)%</div></div>
<div class="card"><div class="k">Ổ $($Rec.diskDrive): trống</div><div class="v">$($Rec.diskFreeGB) GB</div></div>
</div>
$orph
<div class="card"><div class="k">Lý do trạng thái</div><ul>$reasons</ul></div>
<div class="grid">
<div class="card"><div class="k">RAM trống (GB) - 240 mẫu gần nhất</div>$ram</div>
<div class="card"><div class="k">Ổ đĩa trống (GB)</div>$disk</div>
<div class="card"><div class="k">Commit (%)</div>$commit</div>
</div>
<div class="card"><div class="k">Top tiến trình theo RAM</div><table>$top</table></div>
</div></body></html>
"@
    $out = Join-Path (Initialize-RgHome) 'state\status.html'
    $tmp = "$out.tmp"
    [IO.File]::WriteAllText($tmp, $html, (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tmp -Destination $out -Force
}

# ---------- CPU kiểu Task Manager: từng nhân + từng tiến trình ----------

$script:RgPrevCore = @{}; $script:RgPrevProc = @{}; $script:RgCpuInfo = $null; $script:RgBootTime = $null; $script:RgLastProcs = @()

# % mỗi nhân logic từ bộ đếm RAW (delta giữa hai lần lấy mẫu). Lần đầu chưa có delta nên trả mảng rỗng.
function Get-RgCoreUsage {
    $out = @()
    try {
        $rows = @(Get-CimInstance Win32_PerfRawData_PerfOS_Processor -ErrorAction Stop | Where-Object { $_.Name -ne '_Total' } | Sort-Object { [int]$_.Name })
        foreach ($r in $rows) {
            $k = [string]$r.Name; $pt = [double]$r.PercentProcessorTime; $ts = [double]$r.Timestamp_Sys100NS
            $v = $null
            if ($script:RgPrevCore.ContainsKey($k)) {
                $o = $script:RgPrevCore[$k]; $dt = $ts - $o.ts
                if ($dt -gt 0) { $v = [math]::Round([math]::Min(100, [math]::Max(0, 100 * (1 - ($pt - $o.pt) / $dt))), 0) }
            }
            $script:RgPrevCore[$k] = @{ pt = $pt; ts = $ts }
            if ($null -ne $v) { $out += $v }
        }
    } catch { }
    return $out
}

function Get-RgCpuInfo {
    if ($null -eq $script:RgCpuInfo) {
        $name = ''; $phys = 0; $logi = [Environment]::ProcessorCount; $mhz = 0
        try {
            $cs = @(Get-CimInstance Win32_Processor)
            $name = ([string]$cs[0].Name).Trim(); $mhz = [int]$cs[0].MaxClockSpeed
            $phys = [int](($cs | Measure-Object NumberOfCores -Sum).Sum); $logi = [int](($cs | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
        } catch { }
        $script:RgCpuInfo = [pscustomobject]@{ name = $name; physical = $phys; logical = $logi; mhz = $mhz }
    }
    return $script:RgCpuInfo
}

function Get-RgUptimeSec {
    if ($null -eq $script:RgBootTime) { try { $script:RgBootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { return 0 } }
    return [int]((Get-Date) - $script:RgBootTime).TotalSeconds
}

# CPU% mỗi tiến trình = delta TotalProcessorTime / (thời gian thực * số nhân logic), giống Task Manager.
function Get-RgProcRows($Table, [int]$Logical) {
    $now = [Diagnostics.Stopwatch]::GetTimestamp(); $freq = [double][Diagnostics.Stopwatch]::Frequency
    $byPid = @{}; foreach ($t in $Table) { $byPid[[int]$t.Pid] = $t }
    $ledger = @{}; foreach ($e in (Read-RgLedger)) { $ledger[[int]$e.pid] = $true }
    $rows = New-Object System.Collections.ArrayList; $newPrev = @{}
    foreach ($p in [Diagnostics.Process]::GetProcesses()) {
        try {
            $id = $p.Id
            if ($id -eq 0) { continue }
            $cpuSec = $null
            try { $cpuSec = $p.TotalProcessorTime.TotalSeconds } catch { }
            $cpu = 0.0
            if ($null -ne $cpuSec) {
                $newPrev[$id] = @{ c = $cpuSec; t = $now }
                if ($script:RgPrevProc.ContainsKey($id)) {
                    $o = $script:RgPrevProc[$id]; $dw = ($now - $o.t) / $freq
                    if ($dw -gt 0 -and $cpuSec -ge $o.c) { $cpu = [math]::Round(100 * ($cpuSec - $o.c) / ($dw * [math]::Max(1, $Logical)), 1) }
                }
            }
            $t = $byPid[$id]
            [void]$rows.Add([pscustomobject]@{
                    pid = $id; name = $p.ProcessName.ToLowerInvariant(); cpu = [math]::Min(100, $cpu); ramMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
                    group = $(if ($t) { $t.Group } else { 'other' }); agent = $ledger.ContainsKey($id)
                    session = $(try { [int]$p.SessionId } catch { $null })
                })
        } finally { $p.Dispose() }
    }
    $script:RgPrevProc = $newPrev
    return @($rows)
}

function Invoke-RgWatchTick {
    param([switch]$NoToast)
    $home_ = Initialize-RgHome
    $snap = Get-RgSnapshot -SkipCpu
    # Bảng process là phần tốn nhất: dùng cache, chỉ làm mới mỗi TableRefreshSec giây.
    if ($null -eq $script:RgTableCache -or ((Get-Date) - $script:RgTableAt).TotalSeconds -ge $script:TableRefreshSec) {
        $script:RgTableCache = Get-RgProcessTable
        $script:RgTableAt = Get-Date
    }
    $table = $script:RgTableCache
    $budget = Get-RgBudget -Task 'session' -Snapshot $snap -Table $table
    $script:RgLastReasons = @($budget.reasons)

    $st = Read-RgWatcherState
    $interval = [math]::Max(1, [int](Get-RgSettings).intervalSec)
    $needed = [math]::Max(1, [int][math]::Ceiling($script:LowerHoldSec / $interval))
    $eff = Get-RgEffectiveState ([string]$st.state) ([int]$st.lowerCount) ([string]$budget.state) $needed
    $changed = ($eff.state -ne [string]$st.state)

    $cpuInfo = Get-RgCpuInfo
    $cores = @(Get-RgCoreUsage)
    $procs = @(Get-RgProcRows $table ([int]$cpuInfo.logical))
    $script:RgLastProcs = $procs
    $cpuPct = $snap.cpuPct
    if ($cores.Count -gt 0) { $cpuPct = [math]::Round(($cores | Measure-Object -Average).Average, 0) }
    $top = @($procs | Sort-Object ramMB -Descending | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ name = $_.name; ramMB = $_.ramMB } })
    $topCpu = @($procs | Where-Object { $_.cpu -gt 0 } | Sort-Object cpu -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ pid = $_.pid; name = $_.name; cpu = $_.cpu; ramMB = $_.ramMB } })
    $orph = @(Get-RgLedgerOrphans)
    $rec = [pscustomobject]@{
        ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); state = $eff.state; rawState = $budget.state
        availRamGB = $snap.availRamGB; totalRamGB = $snap.totalRamGB; commitPct = $snap.commitPct; cpuPct = $cpuPct
        diskDrive = $snap.diskDrive; diskFreeGB = $snap.diskFreeGB
        drives = @($snap.drives | ForEach-Object { [pscustomobject]@{ drive = $_.drive; label = $_.label; freeGB = $_.freeGB; totalGB = $_.totalGB; state = $_.state; isSystem = $_.isSystem } })
        heavy = $budget.heavyRunning; ledgerOrphans = $orph.Count; top = $top
        cores = $cores; topCpu = $topCpu; procCount = $procs.Count; uptimeSec = (Get-RgUptimeSec)
        procTop = @(Get-RgProcTop $procs)
    }
    $mf = Join-Path $home_ ('state\metrics-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
    Add-Content -LiteralPath $mf -Value (ConvertTo-Json -InputObject $rec -Depth 4 -Compress) -Encoding UTF8

    $toasted = $false
    if ($changed) {
        Write-RgLog 'state-change' ([ordered]@{ from = $st.state; to = $eff.state; reasons = $budget.reasons })
        $worse = [array]::IndexOf($script:RgStates, $eff.state) -gt [array]::IndexOf($script:RgStates, [string]$st.state)
        $cool = $true
        if ($st.lastToastState -eq $eff.state -and $st.lastToastUtc) {
            $cool = ((Get-Date).ToUniversalTime() - [datetime]::Parse([string]$st.lastToastUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')).TotalMinutes -ge $script:ToastCooldownMin
        }
        if (-not $NoToast -and $cool -and ($worse -or $eff.state -eq 'Normal')) {
            $tt = Get-RgToastText ([string]$eff.state) ([bool]$worse) $budget $snap (Get-RgConfig)
            $toasted = Send-RgToast $tt.title $tt.body
            if ($toasted) { $st.lastToastState = $eff.state; $st.lastToastUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
    }

    # 'would-act': chỉ ghi nhận việc chế độ tự động SẼ làm. Chỉ ghi khi tập orphan đổi để log không phình.
    $key = (@($orph | ForEach-Object { "$($_.pid):$($_.start)" }) -join ',')
    if ([array]::IndexOf($script:RgStates, $eff.state) -ge 2 -and $orph.Count -gt 0 -and $key -ne [string]$st.lastOrphanKey) {
        Write-RgLog 'would-kill-orphans' ([ordered]@{ state = $eff.state; items = @($orph | ForEach-Object { [ordered]@{ pid = $_.pid; name = $_.name; label = $_.label } }) })
    }
    $st.lastOrphanKey = $key

    $newState = [pscustomobject]@{
        state = $eff.state; lowerCount = $eff.lowerCount
        lastToastState = [string]$st.lastToastState; lastToastUtc = [string]$st.lastToastUtc; lastOrphanKey = $key
    }
    Write-RgWatcherState $newState
    try { Write-RgStatusHtml $rec $budget $eff.state } catch { Write-RgLog 'status-html-error' ([string]$_) }
    return $rec
}

# ---------- main ----------
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-source (test): chỉ nạp hàm

if (-not $Once) {
    $created = $false
    $mutex = New-Object Threading.Mutex($true, 'Local\ResourceGuardWatcher', [ref]$created)
    if (-not $created) { Write-Host 'Watcher đã chạy.'; exit 0 }
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'Idle' } catch { }
    Write-RgLog 'watcher-start' ([ordered]@{ pid = $PID; intervalSec = $IntervalSec; mode = 'monitor-only' })
    $n = 0
    try {
        while ($true) {
            try { [void](Invoke-RgWatchTick -NoToast:$NoToast) } catch { Write-RgLog 'watcher-error' ([string]$_) }
            if (($n++ % 240) -eq 0) { Remove-RgOldMetrics }
            $wait = if ($IntervalSec -gt 0) { $IntervalSec } else { (Get-RgSettings).intervalSec }
            Start-Sleep -Seconds $wait
        }
    } finally { Write-RgLog 'watcher-stop' ([ordered]@{ pid = $PID }); $mutex.ReleaseMutex() }
} else {
    $r = Invoke-RgWatchTick -NoToast:$NoToast
    if ($Json) { $r | ConvertTo-Json -Depth 4 } else { "State=$($r.state) (raw $($r.rawState)) RAM free $($r.availRamGB)/$($r.totalRamGB) GB, commit $($r.commitPct)%, disk $($r.diskDrive): $($r.diskFreeGB) GB. Status: $(Join-Path (Get-RgHome) 'state\status.html')" }
}
