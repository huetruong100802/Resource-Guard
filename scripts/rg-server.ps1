# rg-server.ps1 - chạy watcher + UI realtime trên http://localhost:<port>/ (chỉ nghe loopback).
#   rg-server.ps1                 # chạy foreground trong terminal, in URL, mở trình duyệt; Ctrl+C để dừng
#   rg-server.ps1 -Detach         # chạy ngầm (ẩn), in URL rồi trả terminal; dừng bằng rg-server.ps1 -Stop
#   rg-server.ps1 -Port 9000 -NoOpen -NoToast
# Giám sát realtime (SSE) + quản lý dọn dẹp: quét ổ đĩa, chính sách giữ/dọn, tự dọn nền, nhờ agent đánh giá.
# Mọi thao tác xoá/kill đi qua Invoke-RgApply (allowlist + revalidate); client chỉ gửi key, không gửi đường dẫn.
[CmdletBinding()]
param([int]$Port = 8765, [switch]$NoOpen, [switch]$NoToast, [switch]$Detach, [switch]$Stop, [switch]$Force)
$ErrorActionPreference = 'Stop'
$argNoToast = [bool]$NoToast; $argPort = $Port; $argNoOpen = [bool]$NoOpen; $argDetach = [bool]$Detach; $argStop = [bool]$Stop; $argForce = [bool]$Force
. (Join-Path $PSScriptRoot 'rg-watcher.ps1')   # nạp hàm (rg-watcher tự return khi bị dot-source)
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
. (Join-Path $PSScriptRoot 'rg-insight.ps1')
. (Join-Path $PSScriptRoot 'rg-proc.ps1')
. (Join-Path $PSScriptRoot 'rg-agent.ps1')
$NoToast = [switch]$argNoToast; $Port = $argPort

$script:UiDir = Join-Path $PSScriptRoot '..\ui'
$script:InfoPath = Join-Path (Initialize-RgHome) 'state\server.json'

function Read-RgServerInfo {
    if (Test-Path -LiteralPath $script:InfoPath) {
        try { return (Get-Content -LiteralPath $script:InfoPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Get-RgLiveInfo {   # trả server.json chỉ khi process đó còn sống
    $i = Read-RgServerInfo
    if ($i -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue)) { return $i }
    return $null
}

# ---------- Stop / Detach (chạy ở process gọi, không vào server) ----------
if ($argStop) {
    $i = Get-RgLiveInfo
    if (-not $i) { Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue; 'Không có server đang chạy.'; return }
    $procId = [int]$i.pid
    $graceful = $false
    if (-not $argForce) {
        # Dừng êm qua API: đóng listener, nhả mutex, huỷ job chỉ-đọc. Từ chối nếu đang dọn/xoá dở.
        try {
            $r = Invoke-RestMethod -Method Post -Uri ($i.url + 'api/shutdown') -Headers @{ 'X-RG-Client' = 'ui' } -ContentType 'application/json' -Body '{}' -TimeoutSec 5
            $graceful = [bool]$r.ok
        } catch {
            $body = $null
            try { $body = ConvertFrom-Json ([string]$_.ErrorDetails.Message) } catch { }
            if ($body -and $body.busy) { "Chưa dừng: $($body.error) Chờ xong rồi chạy lại, hoặc dùng -Force để buộc dừng."; return }
        }
        if ($graceful) {
            try { Wait-Process -Id $procId -Timeout 10 -ErrorAction Stop } catch { }
        }
    }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        $how = if ($argForce) { 'buộc dừng' } else { 'không phản hồi nên buộc dừng' }
    } else { $how = 'dừng êm' }
    Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue
    "Đã dừng Resource Guard ($how, pid $procId)."
    return
}

$existing = Get-RgLiveInfo
if ($existing) {
    "Resource Guard đã chạy: $($existing.url)  (pid $($existing.pid))"
    if (-not $argNoOpen -and -not $argDetach) { Start-Process $existing.url }
    return
}

if ($argDetach) {
    $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Port', $argPort, '-NoOpen')
    if ($argNoToast) { $a += '-NoToast' }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'   # 5.1: toast WinRT hoạt động
    if (-not (Test-Path $exe)) { $exe = (Get-Process -Id $PID).Path }
    [void](Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden)
    for ($k = 0; $k -lt 40; $k++) {
        Start-Sleep -Milliseconds 250
        $i = Get-RgLiveInfo
        if ($i) { "Resource Guard chạy ngầm: $($i.url)  (pid $($i.pid)). Dừng: nút ""Thoát Resource Guard"" trên giao diện, hoặc rg stop"; if (-not $argNoOpen) { Start-Process $i.url }; return }
    }
    throw 'Server không lên sau 10 giây; xem logs\rg-*.jsonl.'
}

# ---------- Helpers HTTP ----------

function Send-Bytes($Ctx, [int]$Status, [string]$Type, [byte[]]$Bytes) {
    $r = $Ctx.Response
    $r.StatusCode = $Status; $r.ContentType = $Type; $r.ContentLength64 = $Bytes.Length
    $r.Headers['Cache-Control'] = 'no-store'
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length); $r.OutputStream.Close()
}
function Send-Json($Ctx, $Obj, [int]$Status = 200) {
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Obj -Depth 6 -Compress)))
}

# Chống DNS-rebinding / CSRF: Host phải là loopback; POST phải có header tuỳ biến (buộc preflight CORS) và Origin (nếu có) cùng gốc.
function Test-RgRequestAllowed($Ctx, [int]$Port) {
    $req = $Ctx.Request
    $okHosts = @("localhost:$Port", "127.0.0.1:$Port")
    if ($okHosts -notcontains [string]$req.Headers['Host']) { return $false }
    if ($req.HttpMethod -ne 'GET') {
        if ($req.Headers['X-RG-Client'] -ne 'ui') { return $false }
        $o = [string]$req.Headers['Origin']
        if ($o -and (@("http://localhost:$Port", "http://127.0.0.1:$Port") -notcontains $o)) { return $false }
    }
    return $true
}

function Send-RawJson($Ctx, [string]$Json, [int]$Status = 200) {
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Json))
}

$script:StaticTypes = @{ '.css' = 'text/css; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.svg' = 'image/svg+xml' }

function Read-RgBody($Req) {
    if ($Req.ContentLength64 -gt 262144) { throw 'Body quá lớn.' }
    $b = (New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
    if (-not $b) { return $null }
    return (ConvertFrom-Json $b)
}

# Chạy script nền ở process riêng (server không bị chặn khi máy lag). Đường dẫn có dấu cách được bọc nháy.
function Start-RgJob([string]$Script, [string[]]$ScriptArgs = @()) {
    $exe = (Get-Process -Id $PID).Path
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot $Script) + '"')) + $ScriptArgs
    [void](Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden)
}

function Test-RgJobRunning([string]$File) {
    $j = Get-RgJobState $File
    return [bool]($j -and $j.status -eq 'running')
}

# Job chỉ-đọc (quét ổ, quét ứng viên, agent): huỷ cả cây tiến trình khi thoát. Job ghi (dọn/khôi phục/tự dọn) không bao giờ bị huỷ ở đây.
function Stop-RgReadOnlyJobs {
    foreach ($f in @('scan-breakdown.progress.json', 'scan-candidates.progress.json', 'agent.progress.json')) {
        $j = Get-RgJobState $f
        if (-not ($j -and $j.status -eq 'running' -and $j.pid)) { continue }
        $p = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
        if (-not $p -or @('pwsh', 'powershell') -notcontains $p.ProcessName) { continue }   # chống PID bị tái sử dụng
        & taskkill.exe /PID ([int]$j.pid) /T /F 2>&1 | Out-Null
        $j.status = 'error'; $j.message = 'đã huỷ vì Resource Guard thoát'
        try { Write-RgJobState $f $j } catch { }
    }
}

function Read-RgStateText([string]$Name) {
    $p = Join-Path (Initialize-RgHome) ("state\" + $Name)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Read-RgFileShared $p)
}

function Get-RgRecentEvents([int]$Max = 30) {
    $dir = Join-Path (Initialize-RgHome) 'logs'
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'rg-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 3)) {
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -Tail 400 -Encoding UTF8 | Where-Object { $_ -match '"event":"(state-change|would-kill-orphans|settings-change|watcher-start|server-start|auto-run|manual-cleanup|policy-change|thresholds-change|agent-eval|proc-priority)"' })) {
            try { $out += ConvertFrom-Json $l } catch { }
        }
        if ($out.Count -ge $Max) { break }
    }
    return @($out | Sort-Object ts -Descending | Select-Object -First $Max)
}

function Get-RgThresholds {
    $c = Get-RgConfig
    return [ordered]@{
        ramAvailGB = [ordered]@{ normalAbove = $c.ram.normalAboveGB; cautionFrom = $c.ram.cautionFromGB; restrictedFrom = $c.ram.restrictedFromGB }
        diskFreeGB = [ordered]@{ normalAbove = $c.disk.normalAboveGB; cautionFrom = $c.disk.cautionFromGB }
        commitPct  = [ordered]@{ restricted = $c.commit.restrictedPct; critical = $c.commit.criticalPct }
    }
}

function Send-RgSse($Clients, [string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    foreach ($c in @($Clients.ToArray())) {
        try { $c.OutputStream.Write($bytes, 0, $bytes.Length); $c.OutputStream.Flush() }
        catch { [void]$Clients.Remove($c); try { $c.Close() } catch { } }
    }
}

# ---------- Mở listener ----------

$mutexCreated = $false
$mutex = New-Object Threading.Mutex($true, 'Local\ResourceGuardWatcher', [ref]$mutexCreated)
if (-not $mutexCreated) { throw 'Một watcher khác (rg-watcher.ps1 / Scheduled Task) đang chạy. Gỡ nó trước: Install-Watcher.ps1 -Uninstall, hoặc dùng trang status.html của nó.' }

$listener = $null
for ($p = $Port; $p -lt $Port + 20; $p++) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/"); $l.Prefixes.Add("http://127.0.0.1:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { try { $l.Close() } catch { } }
}
if (-not $listener) { $mutex.ReleaseMutex(); throw "Không mở được cổng nào trong $Port-$($Port + 19)." }

$url = "http://localhost:$Port/"
Set-Content -LiteralPath $script:InfoPath -Value (ConvertTo-Json ([ordered]@{ pid = $PID; port = $Port; url = $url; startedUtc = (Get-Date).ToUniversalTime().ToString('o') }) -Compress) -Encoding UTF8
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
Write-RgLog 'server-start' ([ordered]@{ pid = $PID; url = $url; mode = (Get-RgPolicy).mode })
$script:JournalRecovered = @()
try { $script:JournalRecovered = @(Resolve-RgJournalPending) } catch { Write-RgLog 'journal-resolve-error' ([string]$_) }   # hành động dở từ lần chạy trước (A1)
$script:RetentionAt = [datetime]::MinValue

Write-Host ''
Write-Host "  Resource Guard đang chạy (tự dọn: $((Get-RgPolicy).mode))" -ForegroundColor Green
Write-Host "  UI realtime : $url" -ForegroundColor Cyan
Write-Host "  Cài đặt     : ${url}#settings    (chu kỳ lấy mẫu hiện tại: $((Get-RgSettings).intervalSec)s)"
Write-Host "  Dừng        : nút ""Thoát Resource Guard"" trên giao diện, hoặc Ctrl+C trong terminal này (đóng cửa sổ này cũng dừng app)"
Write-Host ''
if (-not $argNoOpen) { try { Start-Process $url } catch { } }

# ---------- Vòng chính: nhận request + lấy mẫu theo chu kỳ ----------

$sse = New-Object System.Collections.ArrayList
$script:AutoSpawnedAt = [datetime]::MinValue
$script:ScanCheckAt = [datetime]::MinValue; $script:ScanAutoAt = $null; $script:CpuRing = New-Object System.Collections.ArrayList   # quét nền tự làm mới (P10)
$script:StopRequested = $false
$live = $null
# Có số liệu ngay từ request đầu (A6): nạp bản live.json của lần chạy trước (nếu còn mới) đánh dấu stale; tick đầu tiên sẽ thay nó.
try {
    $lj = Read-RgStateText 'live.json'
    if ($lj) {
        $ol = ConvertFrom-Json $lj
        $olAt = [datetime]::MinValue
        if ($ol.ts -and [datetime]::TryParseExact([string]$ol.ts, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$olAt) -and ((Get-Date) - $olAt).TotalMinutes -le 30) {
            $ol | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
            $live = $ol
        }
    }
} catch { }
# Tick đầu tiên chạy nặng (~vài giây khi nguội): lùi 2 giây để loạt request đầu của UI được phục vụ trước.
$nextSample = (Get-Date).AddSeconds(2)
$nextBeat = (Get-Date).AddSeconds(10)
$accept = $listener.GetContextAsync()
try {
    while ($listener.IsListening -and -not $script:StopRequested) {
        $got = $false
        try { $got = $accept.Wait(200) } catch { $accept = $listener.GetContextAsync(); Start-Sleep -Milliseconds 200 }
        if ($got) {
            $ctx = $accept.Result
            $accept = $listener.GetContextAsync()
            try {
                $req = $ctx.Request
                $path = $req.Url.AbsolutePath
                if (-not (Test-RgRequestAllowed $ctx $Port)) { Send-Bytes $ctx 403 'text/plain' ([Text.Encoding]::UTF8.GetBytes('forbidden')) }
                elseif ($path -eq '/' -or $path -eq '/index.html') {
                    $f = Join-Path $script:UiDir 'index.html'
                    Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($f))
                }
                elseif ($path -eq '/api/shutdown' -and $req.HttpMethod -eq 'POST') {
                    $busyNames = @()
                    if (Test-RgJobRunning 'cleanup.progress.json') { $busyNames += 'dọn dẹp/khôi phục' }
                    if (Test-RgJobRunning 'auto.progress.json') { $busyNames += 'tự dọn' }
                    if ($busyNames.Count) {
                        Send-Json $ctx ([ordered]@{ ok = $false; busy = $true; error = 'Đang có lượt ' + ($busyNames -join ' và ') + ' chưa xong; thoát lúc này có thể bỏ dở thao tác xoá.' }) 409
                    } else {
                        Stop-RgReadOnlyJobs
                        Send-Json $ctx ([ordered]@{ ok = $true })
                        $script:StopRequested = $true
                    }
                }
                elseif ($path -eq '/api/state') { Send-Json $ctx $live }
                elseif ($path -eq '/api/effect' -and $req.HttpMethod -eq 'GET') {
                    # Hiệu quả của dọn dẹp (A5): GB giải phóng, số mục, số lần khôi phục, ai duyệt; đọc từ journal
                    $ed = 30; $eq = 0
                    if ([int]::TryParse([string]$req.QueryString['days'], [ref]$eq) -and $eq -ge 1) { $ed = [math]::Min(365, $eq) }
                    Send-Json $ctx (Get-RgEffectMetrics $ed)
                }
                elseif ($path -eq '/api/health' -and $req.HttpMethod -eq 'GET') {
                    # Sức khoẻ ghi dữ liệu (A1): lỗi ghi file/log/journal và hành động bị ngắt giữa chừng ở lần chạy trước
                    $ioh = Get-RgIoHealth
                    Send-Json $ctx ([ordered]@{ ok = [bool]$ioh.ok; io = $ioh; journalOpen = @(Get-RgJournalPending).Count; recovered = @($script:JournalRecovered); resumablePlans = @(Get-RgResumablePlans) })
                }
                elseif ($path -eq '/api/leases' -and $req.HttpMethod -eq 'GET') {
                    # Phiên agent đang giữ lease + giữ chỗ preflight + tiến trình quan sát được từ cây tiến trình (ledger tầng 2). Chỉ đọc, không có thông tin prompt.
                    $lcfg = Get-RgConfig
                    $ls = @(Get-RgLeases $lcfg)
                    $obs = @(); if ($ls.Count) { try { $obs = @(Get-RgObservedLedger -Cfg $lcfg -Leases $ls) } catch { } }
                    Send-Json $ctx ([ordered]@{ leases = $ls; reservations = @(Get-RgReservations $lcfg | ForEach-Object { [ordered]@{ id = $_.id; sessionId = $_.sessionId; task = $_.task; estimateGB = $_.estimateGB; createdUtc = $_.createdUtc; expiresUtc = $_.expiresUtc } })
                            subagents = [int](@($ls | ForEach-Object { [int]$_.subagents } | Measure-Object -Sum).Sum); observed = $obs })
                }
                elseif ($path -eq '/api/autonomy' -and $req.HttpMethod -eq 'GET') {
                    # Mức tự chủ theo nhóm + banner + đề nghị nâng/hạ theo số liệu + danh sách action (E1-E4). Chỉ đọc.
                    $apol = Get-RgPolicy
                    Send-Json $ctx ([ordered]@{ mode = $apol.mode; groups = @(Get-RgAutonomyView $apol); banner = (Get-RgAutonomyBanner); advice = (Get-RgAutonomyAdvice (Get-RgConfig) $apol)
                            actions = @(Get-RgActionList); demotions = @((Read-RgAutonomyState).demotions); pinConfigured = (Test-RgPinConfigured) })
                }
                elseif ($path -eq '/api/autonomy/level' -and $req.HttpMethod -eq 'POST') {
                    try {   # đặt mức một nhóm; nâng lên L3 cần PIN, hạ thì không
                        $b = Read-RgBody $req
                        $grp = [string]$b.group; $lvl = ([string]$b.level).ToUpperInvariant()
                        $apol = Get-RgPolicy
                        $probe = Get-RgPolicy; $pex = Get-RgAutonomyExplicit $probe; $pex[$grp] = $lvl; $probe.autonomy = $pex
                        $pinOk = $false; $reply = $null
                        if ((Test-RgAutonomyNeedsPin $apol $probe)) {
                            if (-not (Test-RgPinConfigured)) { $reply = [ordered]@{ ok = $false; code = 'pin-not-set'; error = 'Chưa đặt PIN. Đặt ở terminal: resource-manager.ps1 serve setpin' } }
                            elseif ([string]::IsNullOrEmpty([string]$b.pin)) { $reply = [ordered]@{ ok = $false; code = 'pin-required'; error = 'Nâng lên mức tự động cần PIN.' } }
                            else {
                                $pr = Test-RgPin ([string]$b.pin)
                                if ($pr.ok) { $pinOk = $true } else { $reply = [ordered]@{ ok = $false; code = $(if ($pr.locked) { 'pin-locked' } else { 'pin-wrong' }); retryAfterSec = $pr.retryAfterSec; error = $(if ($pr.locked) { "Sai PIN quá nhiều lần, thử lại sau $($pr.retryAfterSec) giây." } else { 'PIN không đúng.' }) } }
                            }
                        }
                        if ($reply) { Send-Json $ctx $reply 403 }
                        else {
                            $sr = Set-RgGroupLevel $grp $lvl $pinOk
                            if ($sr.ok) { Send-Json $ctx ([ordered]@{ ok = $true; groups = @(Get-RgAutonomyView) }) } else { Send-Json $ctx ([ordered]@{ ok = $false; code = $sr.code; error = $sr.error }) 400 }
                        }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/autonomy/snooze' -and $req.HttpMethod -eq 'POST') {
                    try { $b = Read-RgBody $req; $hh = 6; [void][int]::TryParse([string]$b.hours, [ref]$hh); [void](Set-RgAutonomySnooze $hh); Send-Json $ctx ([ordered]@{ ok = $true }) }
                    catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/panic' -and $req.HttpMethod -eq 'POST') {
                    # Dừng khẩn cấp: tắt chính sách + huỷ job nền của Resource-Guard. Không cần PIN (dừng luôn được phép).
                    try { Send-Json $ctx (Invoke-RgPanic -By 'ui') } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 500 }
                }
                elseif ($path -eq '/api/assistant/report' -and $req.HttpMethod -eq 'GET') {
                    # "Báo cáo của trợ lý" (D5): cụm tệp + verdict + tổng hợp. Chỉ metadata; không có đường dẫn từng file, không có tên file ngoài mẫu ≤ 5 tên của cụm.
                    $rep = Get-RgAssistantReport (Get-RgConfig)
                    Send-Json $ctx ([ordered]@{ report = $rep; scan = (Get-RgJobState 'scan-inventory.progress.json'); ask = (Get-RgJobState 'agent.progress.json') })
                }
                elseif ($path -eq '/api/assistant/scan' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'scan-inventory.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-scan.ps1' @('-Mode', 'inventory'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/assistant/ask' -and $req.HttpMethod -eq 'POST') {
                    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Máy này không có lệnh claude; trợ lý vẫn dùng luật tất định.' }) 400 }
                    elseif (Test-RgJobRunning 'agent.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-agent.ps1' @('-Mode', 'clusters'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/assistant/act' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        $cid = [string]$b.clusterId; $act = [string]$b.action
                        if ($cid -notmatch '^[0-9a-f]{12}$') { throw 'clusterId không hợp lệ.' }
                        if (@('compress', 'clean') -notcontains $act) { throw "Hành động chỉ nhận 'compress' hoặc 'clean'." }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        Start-RgJob 'rg-assistant-act.ps1' @('-ClusterId', $cid, '-Action', $act, '-By', 'ui')
                        Send-Json $ctx ([ordered]@{ ok = $true })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/assistant/dismiss' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        if (-not (Add-RgDismissed ([string]$b.clusterId))) { throw 'clusterId không hợp lệ.' }
                        Send-Json $ctx ([ordered]@{ ok = $true })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/history') { Send-Json $ctx @(Read-RgMetricsTail 480) }
                elseif ($path -eq '/api/events') {
                    $mx = 30; $mq = 0
                    if ([int]::TryParse([string]$req.QueryString['max'], [ref]$mq) -and $mq -ge 1) { $mx = [math]::Min(200, $mq) }
                    Send-Json $ctx @(Get-RgRecentEvents $mx)
                }
                elseif ($path -eq '/api/insight' -and $req.HttpMethod -eq 'GET') {
                    if (-not $live) { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Chưa có số liệu, thử lại sau vài giây.' }) 503 }
                    else { Send-Json $ctx (Get-RgInsight $live @($script:RgTableCache)) }
                }
                elseif ($path -eq '/api/drive/history' -and $req.HttpMethod -eq 'GET') {
                    # Dung lượng trống của một ổ, mỗi giờ một điểm (cache 10 phút), để vẽ biểu đồ nhiều ngày. ts là giờ địa phương như metrics.
                    $dq = ([string]$req.QueryString['drive']).Trim().TrimEnd(':').ToUpperInvariant()
                    $dd = 14; $dn = 0
                    if ([int]::TryParse([string]$req.QueryString['days'], [ref]$dn) -and $dn -ge 1) { $dd = [math]::Min(14, $dn) }
                    if ($dq -notmatch '^[A-Z]$') { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Tên ổ không hợp lệ.' }) 400 }
                    else {
                        $sm = Get-RgDriveSamplesCached 14
                        $cut = (Get-Date).AddDays(-$dd)
                        $pts = @(); if ($sm.ContainsKey($dq)) { $pts = @($sm[$dq] | Where-Object { $_.t -ge $cut } | ForEach-Object { [ordered]@{ ts = $_.t.ToString('yyyy-MM-dd HH:mm:ss'); freeGB = [math]::Round($_.freeGB, 2) } }) }
                        Send-Json $ctx ([ordered]@{ drive = $dq; days = $dd; points = $pts })
                    }
                }
                elseif ($path -eq '/api/advice' -and $req.HttpMethod -eq 'GET') {
                    $dr = if ($live -and $live.drives) { @($live.drives) } else { $null }
                    $ramIn = $(if ($live -and $null -ne $live.availRamGB) { [pscustomobject]@{ availGB = [double]$live.availRamGB; totalGB = [double]$live.totalRamGB } } else { $null })
                    $wlIn = @(); try { $wlIn = @(Get-RgLiveWorkloads) } catch { }
                    Send-Json $ctx (Get-RgAdvice -Drives $dr -Ram $ramIn -Workloads $wlIn)
                }
                elseif ($path -eq '/api/process/history' -and $req.HttpMethod -eq 'GET') {
                    $pn = ([string]$req.QueryString['name']).ToLowerInvariant()
                    $pm = 60; $pq = 0
                    if ([int]::TryParse([string]$req.QueryString['min'], [ref]$pq) -and $pq -ge 1) { $pm = [math]::Min(1440, $pq) }
                    if ($pn -notmatch '^[a-z0-9._ -]{1,64}$') { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Tên tiến trình không hợp lệ.' }) 400 }
                    else { Send-Json $ctx (Get-RgProcHistory $pn $pm) }
                }
                elseif ($path -eq '/api/settings' -and $req.HttpMethod -eq 'GET') {
                    Send-Json $ctx ([ordered]@{ intervalSec = (Get-RgSettings).intervalSec; minSec = $script:MinIntervalSec; maxSec = $script:MaxIntervalSec; defaultSec = $script:DefaultIntervalSec; thresholds = (Get-RgThresholds); mode = (Get-RgPolicy).mode; agentAvailable = [bool](Get-Command claude -ErrorAction SilentlyContinue) })
                }
                elseif ($path -eq '/api/settings' -and $req.HttpMethod -eq 'POST') {
                    $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                    $replied = $false
                    try {
                        $sb = ConvertFrom-Json $body
                        $res = [ordered]@{ ok = $true }
                        # Ngưỡng trạng thái (P4): kiểm tra thứ tự/khoảng; nới lỏng khi tự động hoá đang Bật thì cần PIN như chính sách.
                        if ($sb.PSObject.Properties['thresholds'] -and $null -ne $sb.thresholds) {
                            $cfgNow = Get-RgConfig
                            $chk = Test-RgThresholdInput $sb.thresholds $cfgNow
                            if (-not $chk.ok) { Send-Json $ctx ([ordered]@{ ok = $false; error = $chk.error }) 400; $replied = $true }
                            else {
                                $oldT = (Test-RgThresholdInput ([pscustomobject]@{}) $cfgNow).merged
                                if ([string](Get-RgPolicy).mode -eq 'on' -and (Test-RgThresholdsLoosened $oldT $chk.merged)) {
                                    $pinB = $(if ($sb.PSObject.Properties['pin']) { [string]$sb.pin } else { '' })
                                    if (-not (Test-RgPinConfigured)) { Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-not-set'; error = 'Chưa đặt PIN. Đặt ở terminal: resource-manager.ps1 serve setpin' }) 403; $replied = $true }
                                    elseif ([string]::IsNullOrEmpty($pinB)) { Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-required'; error = 'Cần PIN để nới lỏng ngưỡng khi tự động hoá đang Bật.' }) 403; $replied = $true }
                                    else {
                                        $pr = Test-RgPin $pinB
                                        if (-not $pr.ok) {
                                            $code = if ($pr.locked) { 'pin-locked' } else { 'pin-wrong' }
                                            Send-Json $ctx ([ordered]@{ ok = $false; code = $code; retryAfterSec = $pr.retryAfterSec; error = $(if ($pr.locked) { "Sai PIN quá nhiều lần, thử lại sau $($pr.retryAfterSec) giây." } else { 'PIN không đúng.' }) }) 403; $replied = $true
                                        }
                                    }
                                }
                                if (-not $replied) {
                                    Save-RgThresholds $chk.merged
                                    Write-RgLog 'thresholds-change' ([ordered]@{ ramAvailGB = $chk.merged.ramAvailGB; diskFreeGB = $chk.merged.diskFreeGB; commitPct = $chk.merged.commitPct })
                                    $res['thresholds'] = (Get-RgThresholds)
                                }
                            }
                        }
                        if (-not $replied) {
                            if ($sb.PSObject.Properties['intervalSec'] -and $null -ne $sb.intervalSec) {
                                $s = Set-RgSettings ([int]$sb.intervalSec)
                                $nextSample = (Get-Date).AddSeconds($s.intervalSec)
                                $res['intervalSec'] = $s.intervalSec
                            } elseif (-not $sb.PSObject.Properties['thresholds']) { throw 'Thiếu intervalSec hoặc thresholds.' }
                            Send-Json $ctx $res
                        }
                    } catch { if (-not $replied) { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 } }
                }
                elseif ($path -match '^/static/([a-z0-9._-]+\.(css|js|svg))$' -and $req.HttpMethod -eq 'GET') {
                    $f = Join-Path $script:UiDir $Matches[1]
                    if (Test-Path -LiteralPath $f) { Send-Bytes $ctx 200 $script:StaticTypes[[IO.Path]::GetExtension($f)] ([IO.File]::ReadAllBytes($f)) }
                    else { Send-Bytes $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
                }
                elseif ($path -eq '/api/processes') {
                    $pol = Get-RgPolicy
                    $pctx = New-RgProcContext -Policy $pol
                    $tbl = @{}; foreach ($t in @($script:RgTableCache)) { if ($t) { $tbl[[int]$t.Pid] = $t } }
                    $idCfg = Get-RgConfig
                    $idRoots = @(Get-RgWorkspaceRoots $idCfg.cleanup)
                    $idSvc = Get-RgServiceMap
                    $rows = @($script:RgLastProcs | ForEach-Object {
                            $tr = $tbl[[int]$_.pid]
                            $idRow = $(if ($tr) { $tr } else { [pscustomobject]@{ Pid = [int]$_.pid; ParentPid = 0; Name = [string]$_.name; Start = ''; Cmd = ''; Group = [string]$_.group } })
                            $ident = $null
                            try { $ident = Get-RgProcIdentity $idRow $tbl $idCfg $idSvc $idRoots } catch { }
                            $cmdShown = Hide-RgCmdSecret $(if ($tr) { [string]$tr.Cmd } else { '' })
                            if ($cmdShown.Length -gt 600) { $cmdShown = $cmdShown.Substring(0, 600) + '…' }
                            $st = if ($tr) { [string]$tr.Start } else { '' }
                            $low = ($st -ne '') -and $pctx.lowered.ContainsKey("$([int]$_.pid)|$st")
                            $why = ''
                            if ($st -eq '') { $why = 'Chưa đọc được thời điểm khởi động; thử lại sau vài giây.' }
                            elseif ($low) { $why = 'Đã hạ ưu tiên rồi; có thể trả về bình thường.' }
                            else { $why = Get-RgProcLowerVerdict ([int]$_.pid) ([string]$_.name) ([string]$_.group) $(if ($tr) { [string]$tr.Cmd } else { '' }) $_.session $pctx }
                            # Kết thúc (B1): cùng một hàm quyết định với lúc thực thi; chưa đọc được thời điểm khởi động thì chưa cho kết thúc
                            $ev = $null
                            if ($st -ne '') { $ev = Get-RgProcEndVerdict ([int]$_.pid) ([string]$_.name) ([string]$_.group) $(if ($tr) { [string]$tr.Cmd } else { '' }) $_.session $(if ($ident) { [string]$ident.role } else { '' }) $pctx $st }
                            [ordered]@{ pid = $_.pid; name = $_.name; cpu = $_.cpu; ramMB = $_.ramMB; group = $_.group; agent = $_.agent; protected = (Test-RgProcessProtected ([string]$_.name) $pol)
                                start = $st; lowered = $low; canLower = ($why -eq ''); whyNot = $why; cmd = $cmdShown; identity = $ident
                                canEnd = [bool]($ev -and $ev.ok); endNeedsPin = [bool]($ev -and $ev.needsPin); whyNotEnd = $(if ($ev) { [string]$ev.reason } else { 'Chưa đọc được thời điểm khởi động; thử lại sau vài giây.' }) }
                        })
                    $wl = @(Get-RgWorkloads $rows)
                    Send-Json $ctx ([ordered]@{ ts = $(if ($live) { $live.ts } else { $null }); logical = (Get-RgCpuInfo).logical; procs = $rows; workloads = $wl })
                }
                elseif ($path -eq '/api/process/explain' -and $req.HttpMethod -eq 'GET') {
                    # Giải thích tiến trình (D4): là gì, từ đâu, đang phục vụ việc gì. Chỉ nhận pid (+ start); chỉ đọc, không tốn AI.
                    $xp = 0
                    if (-not [int]::TryParse([string]$req.QueryString['pid'], [ref]$xp) -or $xp -le 0) { Send-Json $ctx ([ordered]@{ ok = $false; code = 'bad-pid'; error = 'PID không hợp lệ.' }) 400 }
                    else {
                        $xr = Get-RgProcExplain -ProcId $xp -Start ([string]$req.QueryString['start']) -Cfg (Get-RgConfig) -Table @($script:RgTableCache)
                        if ($xr.ok) { Send-Json $ctx $xr } else { Send-Json $ctx $xr 404 }
                    }
                }
                elseif ($path -eq '/api/process/end' -and $req.HttpMethod -eq 'POST') {
                    # Kết thúc tiến trình từ app (B1). Chỉ nhận pid + start (+ pin khi cần); mọi kiểm tra nằm trong Invoke-RgProcEnd / Stop-RgProcessVerified.
                    try {
                        $b = Read-RgBody $req
                        $bp = 0
                        if ($null -eq $b -or -not [int]::TryParse([string]$b.pid, [ref]$bp) -or $bp -le 0) { Send-Json $ctx ([ordered]@{ ok = $false; code = 'bad-pid'; error = 'PID không hợp lệ.' }) 400 }
                        else {
                            $pinVerified = $false; $pinReply = $null
                            $probe = Test-RgProcEndable $bp ([string]$b.start) (New-RgProcContext -FreshSelf)
                            if ($probe.ok -and $probe.needsPin) {
                                $pinB = $(if ($b.PSObject.Properties['pin']) { [string]$b.pin } else { '' })
                                if (-not (Test-RgPinConfigured)) { $pinReply = [ordered]@{ ok = $false; code = 'pin-not-set'; error = 'Tiến trình này do trợ lý AI giữ nên cần PIN, nhưng chưa đặt PIN. Đặt ở terminal: resource-manager.ps1 serve setpin' } }
                                elseif ([string]::IsNullOrEmpty($pinB)) { $pinReply = [ordered]@{ ok = $false; code = 'pin-required'; error = 'Tiến trình đang do trợ lý AI giữ nên cần PIN.' } }
                                else {
                                    $pr = Test-RgPin $pinB
                                    if ($pr.ok) { $pinVerified = $true }
                                    else { $pinReply = [ordered]@{ ok = $false; code = $(if ($pr.locked) { 'pin-locked' } else { 'pin-wrong' }); retryAfterSec = $pr.retryAfterSec; error = $(if ($pr.locked) { "Sai PIN quá nhiều lần, thử lại sau $($pr.retryAfterSec) giây." } else { 'PIN không đúng.' }) } }
                                }
                            }
                            if ($pinReply) { Send-Json $ctx $pinReply 403 }
                            else {
                                # E1: đi qua cửa duy nhất của Policy Engine (kiểm schema, mức nhóm, rồi Invoke-RgProcEnd)
                                $ar = Invoke-RgAction -Id 'end-process' -Params @{ pid = $bp; start = [string]$b.start } -Actor human -PinVerified $pinVerified
                                $er = $ar.result
                                if (-not $er) { $er = [pscustomobject][ordered]@{ ok = $false; code = $(if ($ar.outcome -eq 'invalid') { 'bad-start' } else { 'autonomy-off' }); pid = $bp; error = [string]$ar.reason } }
                                if ($er.ok) { Send-Json $ctx $er } else { Send-Json $ctx $er 400 }
                            }
                        }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/process/priority' -and $req.HttpMethod -eq 'POST') {
                    # Chỉ nhận pid + start + level (không đường dẫn, không tên). Mọi kiểm tra nằm trong Set-RgProcPriority.
                    try {
                        $b = Read-RgBody $req
                        $bp = 0
                        if ($null -eq $b -or -not [int]::TryParse([string]$b.pid, [ref]$bp) -or $bp -le 0) { Send-Json $ctx ([ordered]@{ ok = $false; error = 'PID không hợp lệ.' }) 400 }
                        else {
                            $ar = Invoke-RgAction -Id 'lower-priority' -Params @{ pid = $bp; start = [string]$b.start; level = [string]$b.level } -Actor human   # E1: cửa duy nhất
                            $pr = $ar.result
                            if (-not $pr) { $pr = [pscustomobject][ordered]@{ ok = $false; pid = $bp; error = [string]$ar.reason } }
                            if ($pr.ok) { Send-Json $ctx $pr } else { Send-Json $ctx $pr 400 }
                        }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/jobs') {
                    Send-Json $ctx ([ordered]@{
                            breakdown = (Get-RgJobState 'scan-breakdown.progress.json'); candidates = (Get-RgJobState 'scan-candidates.progress.json')
                            cleanup = (Get-RgJobState 'cleanup.progress.json'); auto = (Get-RgJobState 'auto.progress.json'); agent = (Get-RgJobState 'agent.progress.json')
                        })
                }
                elseif ($path -eq '/api/drives') {
                    $cfg = Get-RgConfig; $pol = Get-RgPolicy
                    $dl = @(Get-RgDrives)
                    $rows = @($dl | ForEach-Object {
                            $dp = Get-RgDrivePolicy $pol $_.drive
                            $sf = Join-Path (Initialize-RgHome) ("state\scan-breakdown-{0}.json" -f $_.drive)
                            [ordered]@{ drive = $_.drive; label = $_.label; isSystem = $_.isSystem; totalBytes = $_.totalBytes; freeBytes = $_.freeBytes; freeGB = $_.freeGB; totalGB = $_.totalGB; state = $_.state
                                diskTrigger = $dp.diskTrigger; targetFreeGB = $dp.targetFreeGB; overridden = $dp.overridden
                                thresholds = (Get-RgDiskThresholds $cfg $_.drive)
                                scannedUtc = $(if (Test-Path -LiteralPath $sf) { (Get-Item -LiteralPath $sf).LastWriteTimeUtc.ToString('o') } else { $null }) }
                        })
                    $prim = Get-RgPrimaryDrive $dl $cfg
                    Send-Json $ctx ([ordered]@{ drives = $rows; primary = $(if ($prim) { $prim.drive } else { $null }); workspaceRoots = @(Get-RgWorkspaceRoots $cfg.cleanup) })
                }
                elseif ($path -eq '/api/disk') {
                    $q = [string]$req.QueryString['drive']
                    $dl = @(Get-RgDrives)
                    if (-not $q) { $pd = Get-RgPrimaryDrive $dl (Get-RgConfig); $q = $(if ($pd) { $pd.drive } else { 'C' }) }
                    $q = $q.ToUpperInvariant()
                    if ($q -notmatch '^[A-Z]$') { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Tên ổ không hợp lệ.' }) 400 }
                    else {
                        $b = Read-RgStateText ("scan-breakdown-{0}.json" -f $q)
                        if (-not $b) { $b = 'null' }
                        Send-RawJson $ctx ('{"drive":"' + $q + '","breakdown":' + $b + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'scan-breakdown.progress.json') -Compress -Depth 3) + '}')
                    }
                }
                elseif ($path -eq '/api/disk/tree' -and $req.HttpMethod -eq 'GET') {
                    # Cây thư mục của lượt quét gần nhất (scan-tree-<ổ>.json, đã gộp nút nhỏ). Chỉ đọc file cache.
                    $q = ([string]$req.QueryString['drive']).Trim().TrimEnd(':').ToUpperInvariant()
                    if (-not $q) { $dl = @(Get-RgDrives); $pd = Get-RgPrimaryDrive $dl (Get-RgConfig); $q = $(if ($pd) { $pd.drive } else { 'C' }) }
                    if ($q -notmatch '^[A-Z]$') { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Tên ổ không hợp lệ.' }) 400 }
                    else {
                        $tt = Read-RgStateText ("scan-tree-{0}.json" -f $q)
                        if (-not $tt) { Send-Json $ctx ([ordered]@{ ok = $false; error = "Chưa có cây thư mục của ổ ${q}: hãy quét ổ trước." }) 404 }
                        else { Send-RawJson $ctx $tt }
                    }
                }
                elseif ($path -eq '/api/disk/scan' -and $req.HttpMethod -eq 'POST') {
                    $b = $null; try { $b = Read-RgBody $req } catch { }
                    $want = ''; if ($b -and $b.drive) { $want = ([string]$b.drive).Trim().TrimEnd(':').ToUpperInvariant() }
                    $scanScope = ''; $scopeBad = $false
                    if ($b -and $null -ne $b.scope -and [string]$b.scope -ne '') { $scanScope = ([string]$b.scope).Trim().ToLowerInvariant(); if ($scanScope -notin 'focus', 'full') { $scopeBad = $true } }
                    $dl = @(Get-RgDrives)
                    if (-not $want) { $pd = Get-RgPrimaryDrive $dl (Get-RgConfig); if ($pd) { $want = $pd.drive } }
                    if ($want -notmatch '^[A-Z]$' -or -not (@($dl | Where-Object { $_.drive -eq $want }))) { Send-Json $ctx ([ordered]@{ ok = $false; error = "Ổ '$want' không có hoặc không được giám sát." }) 400 }
                    elseif ($scopeBad) { Send-Json $ctx ([ordered]@{ ok = $false; error = "scope chỉ nhận 'focus' hoặc 'full'." }) 400 }
                    elseif (Test-RgJobRunning 'scan-breakdown.progress.json') { $cur = Get-RgJobState 'scan-breakdown.progress.json'; Send-Json $ctx ([ordered]@{ ok = $true; already = $true; drive = [string]$cur.drive }) }
                    else {
                        # Không nói rõ scope: ổ chưa có phần vùng cố định (chưa từng quét đầy đủ) thì quét full để có số nền, còn lại quét focus.
                        if (-not $scanScope) { $scanScope = $(if (Test-Path -LiteralPath (Join-Path (Initialize-RgHome) ('state\scan-fixed-{0}.json' -f $want))) { 'focus' } else { 'full' }) }
                        Start-RgJob 'rg-scan.ps1' @('-Mode', 'breakdown', '-Drive', $want, '-Scope', $scanScope); Send-Json $ctx ([ordered]@{ ok = $true; drive = $want; scope = $scanScope })
                    }
                }
                elseif ($path -eq '/api/candidates' -and $req.HttpMethod -eq 'GET') {
                    $pol = Get-RgPolicy
                    $t = Read-RgStateText 'scan-candidates.json'
                    $cd = $null; if ($t) { try { $cd = ConvertFrom-Json $t } catch { } }
                    $items = @()
                    if ($cd) {
                        $items = @($cd.items | ForEach-Object {
                                $userProt = if ($_.kind -eq 'process') { Test-RgProcessProtected ([string]$_.name) $pol } else { Test-RgPathUserProtected ([string]$_.path) $pol }
                                $ak = if ($_.kind -eq 'process' -or $userProt) { $null } else { Get-RgAgentKeepMatch ([string]$_.path) }
                                $prot = $userProt -or $ak
                                [ordered]@{ key = $_.key; kind = $_.kind; action = $_.action; level = $_.level; path = $_.path; drive = (Get-RgPathDrive ([string]$_.path)); pid = $_.pid; name = $_.name; sizeBytes = $_.sizeBytes
                                    protectedBy = $(if ($userProt) { 'user' } elseif ($ak) { 'agent' } else { $null }); keepReason = $(if ($ak) { $ak.reason } else { $null }); keepUntilUtc = $(if ($ak) { $ak.expiresUtc } else { $null })
                                    ageDays = $_.ageDays; newestWriteUtc = $_.newestWriteUtc; reason = $_.reason; risk = $_.risk; protected = [bool]$prot; needsAdmin = [bool]$_.needsAdmin; young = [bool]$_.young
                                    why = [string]$_.why; impact = [string]$_.impact; regen = [string]$_.regen; regenHint = [string]$_.regenHint; riskLevel = [string]$_.riskLevel
                                    canArchive =(Test-RgArchivable ([string]$_.kind)) -and ($_.action -eq 'delete')
                                    heldBy = @($_.heldBy | Where-Object { $_ })
                                    setting = $(if ($pol.categories.Contains([string]$_.kind)) { $pol.categories[[string]$_.kind] } else { 'keep' }) }
                            })
                    }
                    Send-Json $ctx ([ordered]@{ finishedUtc = $(if ($cd) { $cd.finishedUtc } else { $null }); seconds = $(if ($cd) { $cd.seconds } else { $null }); maxAgeHours = (Get-RgScanMaxAgeHours); items = $items; progress = (Get-RgJobState 'scan-candidates.progress.json') })
                }
                elseif ($path -eq '/api/candidates/scan' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'scan-candidates.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-scan.ps1' @('-Mode', 'candidates'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/cleanup/apply' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        $keys = @($b.keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
                        if ($keys.Count -eq 0) { throw 'Chưa chọn mục nào.' }
                        if ($keys.Count -gt 200) { throw 'Chọn quá nhiều mục (tối đa 200).' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        $cArgs = @('-Keys', ($keys -join ','), '-By', 'ui')
                        if ([bool]$b.archive) { $cArgs += '-Archive' }   # chỉ có tác dụng với nhóm nén được (repo cũ, mục lớn)
                        Start-RgJob 'rg-cleanup.ps1' $cArgs
                        Send-Json $ctx ([ordered]@{ ok = $true; count = $keys.Count })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/cleanup/elevate' -and $req.HttpMethod -eq 'POST') {
                    # Chỉ nhận key của mục được quét gắn needsAdmin; việc xoá thật chạy ở tiến trình riêng SAU khi người dùng bấm "Có" ở hộp UAC của Windows.
                    try {
                        $b = Read-RgBody $req
                        $keys = @($b.keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
                        if ($keys.Count -eq 0) { throw 'Chưa chọn mục nào.' }
                        if ($keys.Count -gt 50) { throw 'Chọn quá nhiều mục (tối đa 50).' }
                        $t = Read-RgStateText 'scan-candidates.json'
                        $cd = $null; if ($t) { try { $cd = ConvertFrom-Json $t } catch { } }
                        if (-not $cd) { throw 'Chưa có danh sách ứng viên; hãy quét trước.' }
                        $ok = @($cd.items | Where-Object { $keys -contains $_.key -and $_.kind -eq 'temp-entry' -and [bool]$_.needsAdmin } | ForEach-Object { [string]$_.key })
                        if ($ok.Count -ne $keys.Count) { throw 'Có mục không thuộc nhóm cần quyền admin.' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        Start-RgJob 'rg-elevate.ps1' @('-Keys', ($ok -join ','))
                        Send-Json $ctx ([ordered]@{ ok = $true; count = $ok.Count })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/archives' -and $req.HttpMethod -eq 'GET') {
                    $rows = @(Read-RgArchives | Sort-Object { [string]$_.createdUtc } -Descending | Select-Object -First 50 | ForEach-Object {
                            [ordered]@{ id = $_.id; original = $_.original; zip = $_.zip; kind = $_.kind; bytes = $_.bytes; zipBytes = $_.zipBytes; createdUtc = $_.createdUtc
                                restoredUtc = $_.restoredUtc; zipExists = (Test-Path -LiteralPath ([string]$_.zip) -PathType Leaf); originalExists = (Test-Path -LiteralPath ([string]$_.original)) } })
                    Send-Json $ctx ([ordered]@{ items = $rows })
                }
                elseif ($path -eq '/api/archive/restore' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        $id = [string]$b.id
                        if ($id -notmatch '^[0-9a-f]{12}$') { throw 'Id không hợp lệ.' }
                        if (@(Read-RgArchives | Where-Object { $_.id -eq $id }).Count -eq 0) { throw 'Không tìm thấy bản nén này.' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        Start-RgJob 'rg-restore.ps1' @('-Id', $id)
                        Send-Json $ctx ([ordered]@{ ok = $true })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/cleanup/last') {
                    $t = Read-RgStateText 'cleanup-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'cleanup.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/api/policy' -and $req.HttpMethod -eq 'GET') {
                    Send-Json $ctx ([ordered]@{ policy = (Get-RgPolicy); pinConfigured = (Test-RgPinConfigured); kinds = $script:RgPolicyKinds })
                }
                elseif ($path -eq '/api/policy' -and $req.HttpMethod -eq 'POST') {
                    $replied = $false
                    try {
                        $b = Read-RgBody $req
                        $old = Get-RgPolicy
                        $new = ConvertTo-RgPolicy $b.policy
                        if (Test-RgPolicyNeedsPin $old $new) {
                            if (-not (Test-RgPinConfigured)) {
                                Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-not-set'; error = 'Chưa đặt PIN. Đặt ở terminal: resource-manager.ps1 serve setpin' }) 403; $replied = $true
                            } elseif ([string]::IsNullOrEmpty([string]$b.pin)) {
                                Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-required'; error = 'Cần PIN cho thay đổi này.' }) 403; $replied = $true
                            } else {
                                $pr = Test-RgPin ([string]$b.pin)
                                if (-not $pr.ok) {
                                    $code = if ($pr.locked) { 'pin-locked' } else { 'pin-wrong' }
                                    Send-Json $ctx ([ordered]@{ ok = $false; code = $code; retryAfterSec = $pr.retryAfterSec; error = $(if ($pr.locked) { "Sai PIN quá nhiều lần, thử lại sau $($pr.retryAfterSec) giây." } else { 'PIN không đúng.' }) }) 403; $replied = $true
                                }
                            }
                        }
                        if (-not $replied) {
                            $saved = Save-RgPolicy $new
                            Write-RgLog 'policy-change' ([ordered]@{ mode = $saved.mode; categories = $saved.categories; protectPaths = @($saved.protectPaths).Count; protectProcesses = @($saved.protectProcesses).Count })
                            Send-Json $ctx ([ordered]@{ ok = $true; policy = $saved; pinConfigured = (Test-RgPinConfigured) })
                        }
                    } catch { if (-not $replied) { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 } }
                }
                elseif ($path -eq '/api/setup' -and $req.HttpMethod -eq 'GET') {
                    Send-Json $ctx (Get-RgSetupInfo)
                }
                elseif ($path -eq '/api/setup' -and $req.HttpMethod -eq 'POST') {
                    try {   # đặt PIN KHÔNG qua đây (chỉ console); chỉ autostart / shortcut / firstRunDone
                        $sr = Invoke-RgSetupPost (Read-RgBody $req)
                        if ($sr.ok) { Send-Json $ctx ([ordered]@{ ok = $true; setup = $sr.info }) } else { Send-Json $ctx ([ordered]@{ ok = $false; error = $sr.error }) 400 }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/auto/preview' -and $req.HttpMethod -eq 'POST') {
                    try {   # chỉ đọc: không lưu bản nháp, không cần PIN
                        $b = Read-RgBody $req
                        if ($null -eq $b -or $null -eq $b.policy) { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Thiếu bản nháp chính sách.' }) 400 }
                        else { Send-Json $ctx (Get-RgAutoPreview $b.policy -Snapshot $live) }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/auto/run' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'auto.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-auto.ps1' @('-Force', '-DryRun', '-Trigger', 'manual'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/auto/last') {
                    $t = Read-RgStateText 'auto-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'auto.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/api/agent/payload') {
                    $pj = ConvertTo-Json -InputObject (New-RgAgentPayload) -Depth 8 -Compress
                    Send-RawJson $ctx ('{"bytes":' + [Text.Encoding]::UTF8.GetByteCount($pj) + ',"payload":' + $pj + '}')
                }
                elseif ($path -eq '/api/agent/run' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'agent.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-agent.ps1'; Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/agent/keep/release' -and $req.HttpMethod -eq 'POST') {
                    # Bỏ giữ một mục do agent bảo vệ. Chỉ nhận key (không nhận đường dẫn từ client). Không cần PIN: chỉ đưa mục về trạng thái
                    # trước khi agent đánh giá, không cấp thêm quyền xoá nào so với policy người dùng đã đặt.
                    try {
                        $b = Read-RgBody $req
                        $t = Read-RgStateText 'scan-candidates.json'
                        $cd = $null; if ($t) { try { $cd = ConvertFrom-Json $t } catch { } }
                        $c = if ($cd) { @($cd.items | Where-Object { $_.key -eq [string]$b.key }) | Select-Object -First 1 } else { $null }
                        $m = if ($c -and $c.kind -ne 'process') { Get-RgAgentKeepMatch ([string]$c.path) } else { $null }
                        if (-not $m) { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Mục này không do agent giữ (hoặc đã hết hạn).' }) 404 }
                        else {
                            [void](Remove-RgAgentKeep ([string]$m.target))
                            Write-RgLog 'agent-keep-release' ([ordered]@{ key = [string]$b.key })
                            Send-Json $ctx ([ordered]@{ ok = $true })
                        }
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/agent/last') {
                    $t = Read-RgStateText 'agent-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'agent.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/events') {
                    $r = $ctx.Response
                    $r.StatusCode = 200; $r.ContentType = 'text/event-stream'; $r.SendChunked = $true
                    $r.Headers['Cache-Control'] = 'no-store'
                    [void]$sse.Add($r)
                    $first = "retry: 3000`n`n"
                    if ($live) { $first += "data: $(ConvertTo-Json -InputObject $live -Depth 6 -Compress)`n`n" }
                    Send-RgSse ([System.Collections.ArrayList]@($r)) $first
                }
                else { Send-Bytes $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
            } catch {
                Write-RgLog 'route-error' ([ordered]@{ path = [string]$path; error = [string]$_ })
                try { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Lỗi nội bộ: ' + [string]$_.Exception.Message }) 500 } catch { try { $ctx.Response.Abort() } catch { } }
            }
        }

        $now = Get-Date
        if ($now -ge $nextSample) {
            try {
                $rec = Invoke-RgWatchTick -NoToast:$NoToast
                $iv = (Get-RgSettings).intervalSec
                $live = [pscustomobject]@{
                    ts = $rec.ts; state = $rec.state; rawState = $rec.rawState; availRamGB = $rec.availRamGB; totalRamGB = $rec.totalRamGB
                    commitPct = $rec.commitPct; cpuPct = $rec.cpuPct; diskDrive = $rec.diskDrive; diskFreeGB = $rec.diskFreeGB; drives = $rec.drives
                    heavy = $rec.heavy; ledgerOrphans = $rec.ledgerOrphans; top = $rec.top
                    reasons = @($script:RgLastReasons); intervalSec = $iv
                    cores = $rec.cores; topCpu = $rec.topCpu; procCount = $rec.procCount; uptimeSec = $rec.uptimeSec; cpuInfo = (Get-RgCpuInfo); procTop = $rec.procTop
                    ioErrors = [int](Get-RgIoHealth).errors; overhead = (Get-RgWatcherOverhead)
                }
                if (((Get-Date) - $script:RetentionAt).TotalHours -ge 6) {   # dọn plans/logs/journal cũ (A1)
                    $script:RetentionAt = Get-Date
                    try { [void](Invoke-RgRetention) } catch { Write-RgLog 'retention-error' ([string]$_) }
                }
                try { Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\live.json') (ConvertTo-Json -InputObject $live -Depth 5 -Compress) } catch { }
                try {   # tự dọn nền: chỉ spawn khi mode != off, có áp lực và hết cooldown
                    $pol = Get-RgPolicy
                    if ([string]$pol.mode -ne 'off' -and ((Get-Date) - $script:AutoSpawnedAt).TotalSeconds -ge 90) {
                        $stress = Get-RgStressInfo $pol (Get-RgConfig) $rec
                        if (-not ($stress.diskStress -or $stress.ramStress)) { [void](Update-RgAutonomyState $stress 0 $false) }   # hết áp lực: mở khoá để lần vượt sau báo lại (E3)
                        if (Test-RgAutoDue $pol $stress) {
                            $script:AutoSpawnedAt = Get-Date
                            Write-RgLog 'auto-spawn' ([ordered]@{ mode = $pol.mode; disk = $stress.diskState; ram = $stress.ramState })
                            Start-RgJob 'rg-auto.ps1' @('-Trigger', 'state')
                        }
                    }
                } catch { Write-RgLog 'auto-check-error' ([string]$_) }
                try {   # quét nền tự làm mới (P10): Test-RgScanDue (thuần) quyết định; ở đây chỉ gom đầu vào rồi khởi động job
                    if ($null -ne $rec.cpuPct) { [void]$script:CpuRing.Add([double]$rec.cpuPct); while ($script:CpuRing.Count -gt 3) { $script:CpuRing.RemoveAt(0) } }
                    if (((Get-Date) - $script:ScanCheckAt).TotalSeconds -ge 60) {
                        $script:ScanCheckAt = Get-Date
                        $scanCfg = Get-RgConfig
                        $refreshH = Get-RgScanRefreshHours $scanCfg
                        if ($refreshH -gt 0) {
                            $anyJob = $false
                            foreach ($pf in 'scan-breakdown', 'scan-candidates', 'cleanup', 'auto', 'agent') { if (Test-RgJobRunning "$pf.progress.json") { $anyJob = $true; break } }
                            $sDir = Join-Path (Initialize-RgHome) 'state'
                            $wt = { param($f) if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTimeUtc } else { $null } }
                            $dv = @(Get-RgDrives | ForEach-Object { [pscustomobject]@{ drive = $_.drive; focusUtc = (& $wt (Join-Path $sDir "scan-breakdown-$($_.drive).json")); fullUtc = (& $wt (Join-Path $sDir "scan-fixed-$($_.drive).json")) } })
                            $dec = Test-RgScanDue -Now (Get-Date) -JobRunning $anyJob -CpuSamples @($script:CpuRing) -LastAutoStart $script:ScanAutoAt -RefreshHours $refreshH -CpuMax (Get-RgScanCpuMax $scanCfg) -MinGapMinutes (Get-RgScanMinGapMinutes $scanCfg) -Drives $dv -CandidatesUtc (& $wt (Join-Path $sDir 'scan-candidates.json'))
                            if ($dec.due) {
                                $script:ScanAutoAt = Get-Date
                                Write-RgLog 'scan-auto' ([ordered]@{ kind = $dec.kind; drive = $dec.drive; scope = $dec.scope; because = $dec.because })
                                if ($dec.kind -eq 'breakdown') { Start-RgJob 'rg-scan.ps1' @('-Mode', 'breakdown', '-Drive', [string]$dec.drive, '-Scope', [string]$dec.scope) }
                                else { Start-RgJob 'rg-scan.ps1' @('-Mode', 'candidates') }
                            }
                        }
                    }
                } catch { Write-RgLog 'scan-auto-error' ([string]$_) }
                Send-RgSse $sse "data: $(ConvertTo-Json -InputObject $live -Depth 6 -Compress)`n`n"
            } catch { Write-RgLog 'server-tick-error' ([string]$_) }
            # Tính từ lúc BẮT ĐẦU tick (không cộng thời gian tick vào chu kỳ); tối thiểu 1s để không quay vòng liên tục.
            $nextSample = $now.AddSeconds((Get-RgSettings).intervalSec)
            $floor = (Get-Date).AddSeconds(1)
            if ($nextSample -lt $floor) { $nextSample = $floor }
        }
        if ($now -ge $nextBeat) { Send-RgSse $sse ": hb`n`n"; $nextBeat = $now.AddSeconds(10) }
    }
}
finally {
    Write-RgLog 'server-stop' ([ordered]@{ pid = $PID; reason = $(if ($script:StopRequested) { 'ui-or-cli' } else { 'ctrl-c-or-error' }) })
    foreach ($c in @($sse.ToArray())) { try { $c.Close() } catch { } }
    try { $listener.Stop(); $listener.Close() } catch { }
    Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue
    try { $mutex.ReleaseMutex() } catch { }
}
