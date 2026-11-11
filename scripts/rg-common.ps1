# rg-common.ps1 - thư viện dùng chung của Resource Guard (dot-source, không chạy trực tiếp).
# Tương thích Windows PowerShell 5.1 và PowerShell 7+. Không gọi LLM, không cần mạng.
# Thông điệp máy-đọc (reasons, blocker) viết bằng tiếng Anh ASCII để agent đọc ổn định.

$script:RgScriptsDir = $PSScriptRoot
$script:RgStates = @('Normal', 'Caution', 'Restricted', 'Critical')
. (Join-Path $PSScriptRoot 'rg-extra.ps1')   # repo cũ / mục lớn / app + nén zip tại chỗ + giải nén
. (Join-Path $PSScriptRoot 'rg-assistant.ps1')   # trợ lý: kiểm kê metadata, cụm tất định, verdict, báo cáo (D1-D3, D5)

# ---------- Cấu hình / thư mục state ----------

function Get-RgHome {
    if ($env:AGENT_RESOURCE_HOME) { return $env:AGENT_RESOURCE_HOME }
    return (Join-Path $HOME '.agent-resource')
}

function Initialize-RgHome {
    $h = Get-RgHome
    foreach ($d in 'state', 'logs', 'plans') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $h $d)) }
    return $h
}

function Expand-RgPath([string]$Path) { return [Environment]::ExpandEnvironmentVariables($Path) }

# Cấu hình = config.default.json được GỘP SÂU với config.json của người dùng (A4): khoá người dùng thắng, khoá thiếu lấy từ default,
# nên bản mới thêm khoá không làm hỏng máy cũ. Mảng và giá trị đơn thì thay hẳn (không nối). Các nhánh dạng "bảng tên -> giá trị"
# (cleanup.cacheDirs) thay hẳn để người dùng bỏ được mục mặc định.
$script:RgConfigReplacePaths = @('cleanup.cacheDirs')

function Merge-RgConfigObject($Base, $Over, [string]$Path = '') {
    # `,$x` giữ nguyên mảng (PowerShell sẽ bung mảng 1 phần tử thành giá trị đơn nếu trả về trực tiếp)
    if ($null -eq $Over) { if ($Base -is [array]) { return , $Base }; return $Base }
    $isObj = { param($o) $null -ne $o -and $o -is [System.Management.Automation.PSCustomObject] }
    if (-not (& $isObj $Base) -or -not (& $isObj $Over) -or ($script:RgConfigReplacePaths -contains $Path)) { if ($Over -is [array]) { return , $Over }; return $Over }
    $out = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $out[$p.Name] = $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        $sub = if ($Path) { "$Path.$($p.Name)" } else { $p.Name }
        if ($out.Contains($p.Name)) { $mv = Merge-RgConfigObject $out[$p.Name] $p.Value $sub; $out[$p.Name] = $mv } else { $out[$p.Name] = $p.Value }
    }
    return [pscustomobject]$out
}

function Get-RgDefaultConfigPath { return (Join-Path $script:RgScriptsDir '..\config.default.json') }

# Phần người dùng tự đặt (thô, chưa gộp default); $null nếu chưa có config.json. Dùng khi cần GHI mà không đóng băng giá trị mặc định.
function Get-RgUserConfigRaw {
    $p = Join-Path (Get-RgHome) 'config.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-RgConfig {
    $def = Get-Content -LiteralPath (Get-RgDefaultConfigPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    $user = $null
    try { $user = Get-RgUserConfigRaw } catch { Write-RgLog 'config-error' ([string]$_.Exception.Message) }   # config hỏng: dùng default, không làm sập server
    if ($null -eq $user) { return $def }
    return (Merge-RgConfigObject $def $user)
}

# ---------- Sức khoẻ ghi file (A1): lỗi ghi KHÔNG được bị nuốt ----------
# Lỗi ghi (ổ đầy, bị khoá, không có quyền) được đếm trong process này và ghi tạm vào state\io-health.json (nếu còn ghi được),
# để UI/rg báo "Resource Guard không ghi được dữ liệu" thay vì để state/log mất âm thầm.
$script:RgIoErrors = 0; $script:RgIoLast = $null

function Register-RgIoError([string]$Op, [string]$Path, $Err) {
    $script:RgIoErrors++
    $script:RgIoLast = [pscustomobject]@{ op = $Op; path = $Path; error = [string]$Err; ts = (Get-Date).ToUniversalTime().ToString('o') }
    try {
        $p = Join-Path (Initialize-RgHome) 'state\io-health.json'
        [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject ([ordered]@{ errors = $script:RgIoErrors; last = $script:RgIoLast }) -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }   # ổ đầy hoàn toàn: đã có bộ đếm trong bộ nhớ, đây chỉ là bản lưu thêm
}

function Get-RgIoHealth {
    $errors = [int]$script:RgIoErrors; $last = $script:RgIoLast
    if ($errors -eq 0) {   # process khác (job nền, watcher riêng) có thể đã ghi nhận lỗi
        $p = Join-Path (Get-RgHome) 'state\io-health.json'
        if (Test-Path -LiteralPath $p) {
            try { $j = ConvertFrom-Json (Read-RgFileShared $p); $errors = [int]$j.errors; $last = $j.last } catch { }
        }
    }
    return [pscustomobject]@{ ok = ($errors -eq 0); errors = $errors; last = $last }
}

function Clear-RgIoHealth {
    $script:RgIoErrors = 0; $script:RgIoLast = $null
    Remove-Item -LiteralPath (Join-Path (Get-RgHome) 'state\io-health.json') -Force -ErrorAction SilentlyContinue
}

# Log là nơi cuối cùng để báo lỗi nên không ném ngoại lệ (không được làm hỏng hành động đang chạy), nhưng lỗi ghi được đếm và báo qua Get-RgIoHealth.
function Write-RgLog([string]$Event, $Data) {
    $file = ''
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $h = Initialize-RgHome
            $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); event = $Event; data = $Data }
            $file = Join-Path $h ('logs\rg-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
            Add-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject $rec -Depth 6 -Compress) -Encoding UTF8 -ErrorAction Stop
            return
        } catch { if ($i -eq 0) { Start-Sleep -Milliseconds 60 } else { Register-RgIoError 'log' $file $_.Exception.Message } }
    }
}

# Ghi file nguyên tử, chịu được việc có process khác đang đọc file đó (UI/server poll). Thử lại vài lần, cuối cùng ghi thẳng.
# Nếu mọi cách đều thất bại thì NÉM lỗi (không nuốt): người gọi phải biết state không được lưu.
function Write-RgFileAtomic([string]$Path, [string]$Text) {
    $enc = New-Object Text.UTF8Encoding($false)
    $lastErr = ''
    for ($i = 0; $i -lt 5; $i++) {
        $tmp = "$Path.$PID.tmp"
        try {
            [IO.File]::WriteAllText($tmp, $Text, $enc)
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Milliseconds (40 * ($i + 1)) }
    }
    Remove-Item -LiteralPath "$Path.$PID.tmp" -Force -ErrorAction SilentlyContinue
    try { [IO.File]::WriteAllText($Path, $Text, $enc) }
    catch { Register-RgIoError 'write' $Path $_.Exception.Message; throw ("Không ghi được file '{0}': {1}" -f $Path, $_.Exception.Message) }
}

# ---------- Journal ghi-trước (A1) ----------
# state\journal.jsonl: mỗi hành động ghi 2 dòng — 'intent' TRƯỚC khi làm, rồi 'done' | 'failed' | 'interrupted' SAU khi làm.
# Intent không ghi được => hành động KHÔNG được thực thi. Khởi động lại: intent không có dòng đóng = bị ngắt giữa chừng.
function Get-RgJournalPath { return (Join-Path (Initialize-RgHome) 'state\journal.jsonl') }

function Add-RgJournalLine($Rec) {
    $p = Get-RgJournalPath
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Rec -Depth 5 -Compress) + "`n")
    $lastErr = ''
    for ($i = 0; $i -lt 4; $i++) {
        $fs = $null
        try {
            $fs = New-Object IO.FileStream($p, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true)
            return
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Milliseconds (50 * ($i + 1)) }
        finally { if ($fs) { $fs.Dispose() } }
    }
    Register-RgIoError 'journal' $p $lastErr
    throw "Không ghi được journal: $lastErr"
}

function New-RgActionId { return ([guid]::NewGuid().ToString('N')).Substring(0, 12) }

# Ghi intent. Ném lỗi nếu không ghi được. Trả actionId để đóng bằng Close-RgJournal.
function Write-RgJournalIntent([string]$Action, [string]$Kind, [string]$Target, [string]$PlanId = '', $Extra = $null) {
    $id = New-RgActionId
    $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); actionId = $id; phase = 'intent'; planId = $PlanId; action = $Action; kind = $Kind; target = $Target; pid = $PID }
    if ($Extra) { $rec['extra'] = $Extra }
    Add-RgJournalLine $rec
    return $id
}

# Đóng một action. Không ném: nếu đóng thất bại thì intent vẫn còn đó và lần khởi động sau sẽ được rà lại.
function Close-RgJournal([string]$ActionId, [string]$Phase, [string]$Detail = '', [long]$Bytes = 0) {
    try { Add-RgJournalLine ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); actionId = $ActionId; phase = $Phase; detail = $Detail; bytes = $Bytes }) } catch { }
}

# Số liệu hiệu quả (A5), đọc từ journal: bao nhiêu GB đã giải phóng, bao nhiêu mục, bao nhiêu lần khôi phục, ai duyệt.
# Dùng cho E4 (nâng/hạ mức tự chủ theo số liệu) và trang Tổng quan.
function Get-RgEffectMetrics([int]$Days = 30) {
    $cut = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('o')
    $all = @(Read-RgJournal)
    $intent = @{}
    foreach ($e in $all) { if ($e.phase -eq 'intent') { $intent[[string]$e.actionId] = $e } }
    $m = [ordered]@{ days = $Days; items = 0; failed = 0; partial = 0; freedBytes = 0L; restores = 0; restoredBytes = 0L; archives = 0; kills = 0
        byKind = [ordered]@{}; byApprover = [ordered]@{}; plans = 0; lastActionUtc = $null; interrupted = 0 }
    $planSet = @{}
    foreach ($c in $all) {
        if ($c.phase -eq 'intent' -or [string]$c.ts -lt $cut) { continue }
        $i = $intent[[string]$c.actionId]
        if (-not $i) { continue }
        if ($c.phase -eq 'interrupted') { $m.interrupted++; continue }
        $m.lastActionUtc = [string]$c.ts
        if ($i.action -eq 'restore') { if ($c.phase -eq 'done') { $m.restores++; $m.restoredBytes += [long]$c.bytes }; continue }
        if ($c.phase -eq 'failed') { $m.failed++; continue }
        if ($c.phase -eq 'partial') { $m.partial++ }
        if ($i.action -eq 'kill') { $m.kills++; continue }
        $m.items++
        if ($i.action -eq 'archive') { $m.archives++ }
        $m.freedBytes += [long]$c.bytes
        $k = [string]$i.kind
        if (-not $m.byKind.Contains($k)) { $m.byKind[$k] = [ordered]@{ items = 0; bytes = 0L } }
        $m.byKind[$k].items++; $m.byKind[$k].bytes += [long]$c.bytes
        $who = if ($i.extra -and $i.extra.approvedBy) { if ([string]$i.extra.approvedBy -eq 'policy') { 'policy' } else { 'human' } } else { 'unknown' }
        if (-not $m.byApprover.Contains($who)) { $m.byApprover[$who] = 0 }
        $m.byApprover[$who]++
        if ($i.planId) { $planSet[[string]$i.planId] = $true }
    }
    $m.plans = $planSet.Count
    $m.restoreRate = if ($m.archives -gt 0) { [math]::Round($m.restores / [double]$m.archives, 3) } else { 0 }
    return [pscustomobject]$m
}

function Read-RgJournal {
    $p = Get-RgJournalPath
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    foreach ($l in @((Read-RgFileShared $p) -split "`n")) {
        if (-not $l.Trim()) { continue }
        try { [void]$out.Add((ConvertFrom-Json $l)) } catch { }   # dòng cuối có thể dang dở nếu mất điện giữa lúc ghi
    }
    return @($out.ToArray())
}

# Các intent chưa có dòng đóng.
function Get-RgJournalPending {
    $closed = @{}; $intents = @()
    foreach ($e in (Read-RgJournal)) {
        if ($e.phase -eq 'intent') { $intents += $e } else { $closed[[string]$e.actionId] = $true }
    }
    return @($intents | Where-Object { -not $closed.ContainsKey([string]$_.actionId) })
}

# Khởi động: mỗi intent mồ côi được xét lại theo thực tế rồi đóng bằng 'interrupted' (kèm kết luận) để không báo lặp.
# Không tự làm lại việc đã dở: xoá dở thì plan vẫn ở trạng thái 'applying' và người dùng/Policy chạy lại apply (revalidate từng mục).
function Resolve-RgJournalPending {
    $res = @()
    foreach ($e in (Get-RgJournalPending)) {
        # process khác (job apply đang chạy) còn sống => intent này chưa mồ côi
        if ($e.pid -and [int]$e.pid -ne $PID -and (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { continue }
        $state = 'unknown'
        if ($e.action -eq 'delete' -or $e.action -eq 'archive') {
            $state = if ($e.target -and (Test-Path -LiteralPath ([string]$e.target))) { 'target-still-present' } else { 'target-gone' }
        } elseif ($e.action -eq 'kill') {
            $state = 'check-process'
        } elseif ($e.action -eq 'restore') {
            # giải nén dở: phần đã ra có thể thiếu file. Báo để người dùng xoá phần dang dở rồi khôi phục lại từ zip (zip không bị đụng).
            $state = if ($e.target -and (Test-Path -LiteralPath ([string]$e.target))) { 'restore-incomplete-check-target' } else { 'restore-not-started' }
        }
        Close-RgJournal ([string]$e.actionId) 'interrupted' $state
        $res += [pscustomobject]@{ actionId = $e.actionId; planId = $e.planId; action = $e.action; kind = $e.kind; target = $e.target; ts = $e.ts; state = $state }
    }
    if ($res.Count -gt 0) { Write-RgLog 'journal-recovered' @{ count = $res.Count; items = @($res | Select-Object -First 20) } }
    return $res
}

# ---------- Retention (A1): plans\*.json và logs\rg-*.jsonl không được phình mãi ----------
function Get-RgRetention($Cfg) {
    $r = [ordered]@{ plansDays = 60; logDays = 30; journalMaxKB = 4096 }
    try {
        if ($Cfg -and $Cfg.PSObject.Properties['retention'] -and $Cfg.retention) {
            foreach ($k in @($r.Keys)) { $p = $Cfg.retention.PSObject.Properties[$k]; if ($p -and [int]$p.Value -gt 0) { $r[$k] = [int]$p.Value } }
        }
    } catch { }
    return [pscustomobject]$r
}

function Invoke-RgRetention {
    param($Cfg = $null)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $rt = Get-RgRetention $Cfg
    $h = Initialize-RgHome
    $removed = [ordered]@{ plans = 0; logs = 0; journalPruned = $false }
    $planCut = (Get-Date).AddDays(-[int]$rt.plansDays)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $h 'plans') -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -ge $planCut) { continue }
        $keep = $false
        try {
            $pl = ConvertFrom-Json (Read-RgFileShared $f.FullName)
            # plan đã duyệt mà chưa chạy xong ('approved' chưa 'applied') không bị xoá theo tuổi
            if ([string]$pl.approval.status -eq 'approved' -and [string]$pl.status -ne 'applied') { $keep = $true }
        } catch { }
        if (-not $keep) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed.plans++ } catch { } }
    }
    $logCut = (Get-Date).AddDays(-[int]$rt.logDays)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $h 'logs') -Filter 'rg-*.jsonl' -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $logCut) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed.logs++ } catch { } }
    }
    $jp = Get-RgJournalPath
    if ((Test-Path -LiteralPath $jp) -and ((Get-Item -LiteralPath $jp).Length -gt ([long]$rt.journalMaxKB * 1KB))) {
        try {   # giữ mọi intent còn mở + các dòng của 1000 action gần nhất
            $all = @(Read-RgJournal)
            $closed = @{}; foreach ($e in $all) { if ($e.phase -ne 'intent') { $closed[[string]$e.actionId] = $true } }
            $recent = @{}; $ids = @($all | ForEach-Object { [string]$_.actionId } | Select-Object -Unique)
            foreach ($id in @($ids | Select-Object -Last 1000)) { $recent[$id] = $true }
            $keepLines = @($all | Where-Object { $recent.ContainsKey([string]$_.actionId) -or -not $closed.ContainsKey([string]$_.actionId) } |
                    ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 5 -Compress })
            Write-RgFileAtomic $jp (($keepLines -join "`n") + "`n")
            $removed.journalPruned = $true
        } catch { Write-RgLog 'retention-error' ([string]$_) }
    }
    if ($removed.plans -gt 0 -or $removed.logs -gt 0 -or $removed.journalPruned) { Write-RgLog 'retention' $removed }
    return [pscustomobject]$removed
}

function Read-RgFileShared([string]$Path) {   # đọc file cho phép bên kia đang ghi/đổi tên
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}

function Get-RgSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------- Snapshot RAM / CPU / disk ----------

function Get-RgSnapshot {
    param([switch]$SkipCpu)   # watcher đã có CPU từng nhân nên bỏ Win32_Processor (chậm)
    $cfg = Get-RgConfig
    $os = Get-CimInstance Win32_OperatingSystem
    $totalVirt = [double]$os.TotalVirtualMemorySize
    $freeVirt = [double]$os.FreeVirtualMemory
    $commitPct = 0
    if ($totalVirt -gt 0) { $commitPct = [math]::Round((1 - $freeVirt / $totalVirt) * 100, 1) }

    $drives = @(Get-RgDrives)
    $drive = ([string]$cfg.disk.drive).TrimEnd(':', '\')
    $diskFree = $null
    $primary = Get-RgPrimaryDrive $drives $cfg
    if ($primary) { $drive = $primary.drive; $diskFree = $primary.freeGB }
    else { try { $diskFree = [math]::Round((New-Object IO.DriveInfo($drive)).AvailableFreeSpace / 1GB, 2) } catch { } }

    $pageFiles = @()
    try {
        $pageFiles = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; allocatedMB = $_.AllocatedBaseSize; usedMB = $_.CurrentUsage }
            })
    } catch { }

    $cpu = $null
    if (-not $SkipCpu) { try { $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average, 0) } catch { } }

    return [pscustomobject]@{
        timeUtc       = (Get-Date).ToUniversalTime().ToString('o')
        availRamGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        totalRamGB    = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        commitPct     = $commitPct
        commitUsedGB  = [math]::Round(($totalVirt - $freeVirt) / 1MB, 2)
        commitLimitGB = [math]::Round($totalVirt / 1MB, 2)
        cpuPct        = $cpu
        diskDrive     = $drive
        diskFreeGB    = $diskFree
        drives        = $drives
        pageFiles     = $pageFiles
    }
}

# ---------- Process table / phân nhóm ----------

# Dấu thời gian dạng compact (không có dấu '-'/':') để ConvertFrom-Json của PS7 không tự đổi thành DateTime.
# Với process: độ phân giải giây. Cùng nguồn (Win32_Process) ở mọi nơi để so sánh ổn định.
function ConvertTo-RgStamp($DateTime) {
    if ($null -eq $DateTime) { return $null }
    return ([datetime]$DateTime).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'
}

function Get-RgNowStamp { return (ConvertTo-RgStamp (Get-Date)) }

# Dọn tay: từ chối nếu lượt quét ứng viên cũ hơn ngưỡng này (TECHNOTE §5). UI đọc ngưỡng qua /api/candidates.
function Get-RgScanMaxAgeHours {
    $h = 12.0   # scan.maxAgeHours trong config (A4); thiếu/không hợp lệ thì 12
    try { $c = Get-RgConfig; if ($c.scan -and $c.scan.PSObject.Properties['maxAgeHours'] -and [double]$c.scan.maxAgeHours -gt 0) { $h = [double]$c.scan.maxAgeHours } } catch { }
    return $h
}
# Tuổi (giờ) của lượt quét; $null nếu không đọc được thời điểm.
function Get-RgScanAgeHours([string]$FinishedUtc) {
    if (-not $FinishedUtc) { return $null }
    try { return ((Get-Date).ToUniversalTime() - [datetime]::Parse($FinishedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime()).TotalHours } catch { return $null }
}
# Fail-closed: không đọc được thời điểm thì coi là cũ.
function Test-RgScanStale([string]$FinishedUtc) {
    $a = Get-RgScanAgeHours $FinishedUtc
    return ($null -eq $a -or $a -gt (Get-RgScanMaxAgeHours))
}

# ---------- Quét nền tự làm mới (P10) ----------
# scan.autoRefreshHours trong config (mặc định 6; 0 = tắt). Thiếu khoá thì dùng mặc định.
function Get-RgScanRefreshHours($Cfg) {
    $h = 6.0
    try { if ($Cfg -and $Cfg.PSObject.Properties['scan'] -and $Cfg.scan -and $Cfg.scan.PSObject.Properties['autoRefreshHours']) { $h = [double]$Cfg.scan.autoRefreshHours } } catch { }
    if ($h -lt 0) { $h = 0 }
    return $h
}

# scan.minGapMinutes: khoảng cách tối thiểu giữa hai lượt tự quét nền (mặc định 10).
function Get-RgScanMinGapMinutes($Cfg) {
    $v = 10.0
    try { if ($Cfg -and $Cfg.PSObject.Properties['scan'] -and $Cfg.scan -and $Cfg.scan.PSObject.Properties['minGapMinutes'] -and [double]$Cfg.scan.minGapMinutes -gt 0) { $v = [double]$Cfg.scan.minGapMinutes } } catch { }
    return $v
}

# scan.cpuMaxPct: chỉ quét nền khi CPU trung bình 3 mẫu cuối thấp hơn mức này (mặc định 40).
function Get-RgScanCpuMax($Cfg) {
    $v = 40.0
    try { if ($Cfg -and $Cfg.PSObject.Properties['scan'] -and $Cfg.scan -and $Cfg.scan.PSObject.Properties['cpuMaxPct']) { $v = [double]$Cfg.scan.cpuMaxPct } } catch { }
    if ($v -le 0) { $v = 40.0 }
    return $v
}

# Hàm THUẦN (không đọc file/đồng hồ): có nên khởi động một lượt quét nền ngay bây giờ không.
#   $Now            thời điểm đang xét.
#   $JobRunning     có bất kỳ job nền nào đang chạy (quét, dọn, tự dọn, agent...).
#   $CpuSamples     các mẫu CPU% gần nhất (cũ -> mới); dùng trung bình 3 mẫu cuối, < $CpuMax mới quét. Chưa đủ 3 mẫu thì chờ.
#   $LastAutoStart  lần gần nhất server tự khởi động quét nền ($null nếu chưa); mỗi lần cách nhau >= $MinGapMinutes.
#   $RefreshHours   scan.autoRefreshHours (<= 0: tắt).
#   $Drives         [{ drive; focusUtc; fullUtc }] focusUtc = lần ghi kết quả breakdown gần nhất (mọi scope), fullUtc = lần quét đầy đủ gần nhất; $null nếu chưa từng.
#   $CandidatesUtc  thời điểm xong lượt quét ứng viên gần nhất ($null nếu chưa).
# Kết quả: { due; kind = breakdown|candidates|$null; drive; scope = focus|full; because }. Mỗi lần một việc: ổ cũ nhất, hoặc quét ứng viên nếu nó cũ hơn.
# Ổ có kết quả cũ hơn $RefreshHours -> quét 'focus'; nếu lượt đầy đủ cũ hơn $FullDays ngày (hoặc chưa có) thì quét 'full'.
function Test-RgScanDue {
    param([datetime]$Now, [bool]$JobRunning, [double[]]$CpuSamples = @(), $LastAutoStart = $null, [double]$RefreshHours = 6, $Drives = @(), $CandidatesUtc = $null,
        [double]$MinGapMinutes = 10, [double]$CpuMax = 40, [double]$FullDays = 7)
    function NoScan([string]$Why) { return [pscustomobject]@{ due = $false; kind = $null; drive = $null; scope = $null; because = $Why } }
    if ($RefreshHours -le 0) { return (NoScan 'Tự làm mới quét nền đang tắt') }
    if ($JobRunning) { return (NoScan 'Đang có tác vụ nền chạy') }
    $cs = @($CpuSamples)
    if ($cs.Count -lt 3) { return (NoScan 'Chưa đủ mẫu CPU để biết máy có rảnh không') }
    $last3 = @($cs[($cs.Count - 3)..($cs.Count - 1)]); $avg = 0.0; foreach ($v in $last3) { $avg += $v }; $avg /= 3
    if ($avg -ge $CpuMax) { return (NoScan ('CPU đang bận (trung bình {0:n0}%)' -f $avg)) }
    if ($null -ne $LastAutoStart -and ($Now - [datetime]$LastAutoStart).TotalMinutes -lt $MinGapMinutes) { return (NoScan ('Vừa quét nền cách đây chưa tới {0:n0} phút' -f $MinGapMinutes)) }

    $inf = [double]::MaxValue
    $best = $null; $bestAge = -1.0
    foreach ($d in @($Drives)) {
        if (-not $d) { continue }
        $age = $(if ($null -eq $d.focusUtc) { $inf } else { ($Now.ToUniversalTime() - ([datetime]$d.focusUtc).ToUniversalTime()).TotalHours })
        if ($age -gt $RefreshHours -and $age -gt $bestAge) { $best = $d; $bestAge = $age }
    }
    $cAge = $(if ($null -eq $CandidatesUtc) { $inf } else { ($Now.ToUniversalTime() - ([datetime]$CandidatesUtc).ToUniversalTime()).TotalHours })
    $candDue = ($cAge -gt $RefreshHours)
    if ($best -and (-not $candDue -or $bestAge -ge $cAge)) {
        $fullAge = $(if ($null -eq $best.fullUtc) { $inf } else { ($Now.ToUniversalTime() - ([datetime]$best.fullUtc).ToUniversalTime()).TotalDays })
        $scope = $(if ($fullAge -gt $FullDays) { 'full' } else { 'focus' })
        $why = $(if ($bestAge -eq $inf) { "Ổ $($best.drive): chưa có kết quả quét" } else { 'Ổ {0}: kết quả quét đã {1:n1} giờ' -f $best.drive, $bestAge })
        return [pscustomobject]@{ due = $true; kind = 'breakdown'; drive = [string]$best.drive; scope = $scope; because = $why }
    }
    if ($candDue) {
        $why = $(if ($cAge -eq $inf) { 'Chưa có kết quả quét mục có thể dọn' } else { 'Kết quả quét mục có thể dọn đã {0:n1} giờ' -f $cAge })
        return [pscustomobject]@{ due = $true; kind = 'candidates'; drive = $null; scope = $null; because = $why }
    }
    return (NoScan 'Kết quả quét còn mới')
}

function Get-RgGroup([string]$Name, [string]$Cmd, $Cfg) {
    if ($Cmd -and $Cfg.agentCmdRegex -and (@('node', 'bun', 'python') -contains $Name) -and ($Cmd -match $Cfg.agentCmdRegex)) {
        return 'agent'
    }
    foreach ($g in @('agent', 'infra', 'test', 'build', 'dev')) {
        foreach ($pat in @($Cfg.groups.$g)) { if ($Name -like $pat) { return $g } }
    }
    return 'other'
}

function Get-RgProcessTable {
    $cfg = Get-RgConfig
    $rows = foreach ($p in (Get-CimInstance Win32_Process)) {
        $n = ([string]$p.Name -replace '\.exe$', '').ToLowerInvariant()
        $cmd = [string]$p.CommandLine
        [pscustomobject]@{
            Pid       = [int]$p.ProcessId
            ParentPid = [int]$p.ParentProcessId
            Name      = $n
            Start     = (ConvertTo-RgStamp $p.CreationDate)
            RamMB     = [math]::Round([double]$p.WorkingSetSize / 1MB, 0)
            Group     = (Get-RgGroup $n $cmd $cfg)
            Cmd       = $cmd
        }
    }
    return @($rows)
}

function Test-RgHeavy($Proc, $Cfg) {
    if ($Proc.Cmd -and $Cfg.heavyExcludeCmdRegex -and ($Proc.Cmd -match $Cfg.heavyExcludeCmdRegex)) { return $false }
    foreach ($h in @($Cfg.heavy)) {
        if ($Proc.Name -like $h.name) {
            if (-not $h.cmdRegex) { return $true }
            if ($Proc.Cmd -and ($Proc.Cmd -match $h.cmdRegex)) { return $true }
        }
    }
    return $false
}

# Chỉ đếm process heavy "gốc" (cha không phải heavy) để 1 lần build = 1 slot, không phải N worker MSBuild.
function Get-RgHeavyRoots($Table, $Cfg) {
    $heavy = @($Table | Where-Object { Test-RgHeavy $_ $Cfg })
    $set = @{}
    foreach ($h in $heavy) { $set[[int]$h.Pid] = $true }
    return @($heavy | Where-Object { -not $set.ContainsKey([int]$_.ParentPid) })
}

# Process build/test/dev mà cha đã chết (hoặc PID cha bị tái sử dụng). Chỉ là ứng viên, KHÔNG phải bằng chứng agent tạo ra.
function Get-RgOrphanCandidates($Table) {
    $byPid = @{}
    foreach ($p in $Table) { $byPid[[int]$p.Pid] = $p }
    $out = @()
    foreach ($p in $Table) {
        if (@('build', 'test', 'dev') -notcontains $p.Group) { continue }
        $par = $byPid[[int]$p.ParentPid]
        if ($null -eq $par -or $par.Start -gt $p.Start) { $out += $p }
    }
    return $out
}

# Trả về CIM process nếu PID còn sống VÀ start time (+ tên) khớp; ngược lại $null. Chống PID reuse.
function Test-RgProcessIdentity([int]$ProcId, [string]$Start, [string]$Name) {
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    if ((ConvertTo-RgStamp $c.CreationDate) -ne $Start) { return $null }
    if ($Name -and (([string]$c.Name -replace '\.exe$', '').ToLowerInvariant() -ne $Name)) { return $null }
    return $c
}

# ---------- Kết thúc tiến trình có xác minh (A2) ----------
# Cửa DUY NHẤT để kết thúc một tiến trình (Invoke-RgApply, nút kết thúc B1, action registry E1 đều gọi hàm này).
# Hàm KHÔNG tự quyết có đủ điều kiện hay không (đó là việc của Get-RgKillBlocker / allowlist lớp tiến trình); nó chỉ:
#   1) kiểm lại PID + start time + tên ngay trước khi tác động (chống PID reuse),
#   2) thử đóng êm (CloseMainWindow) nếu có cửa sổ, chờ GraceSec giây,
#   3) buộc dừng (lá trước, gốc sau), chỉ với hậu duệ thuộc nhóm cho phép (kill.allowedGroups); nhóm khác ghi vào skipped,
#   4) chờ rồi XÁC MINH từng tiến trình đã thật sự thoát.
# Trả { ok; method = graceful|forced|none; exited; reason; tree = [{pid,name,exited}]; skipped = [{pid,name,group}] }.

# Hậu duệ của RootPid (không gồm gốc), lá trước. Bỏ qua mục có start sớm hơn cha (PID bị tái sử dụng).
function Get-RgProcessTree([int]$RootPid, [string]$RootStart) {
    $all = @(Get-CimInstance Win32_Process | ForEach-Object {
            [pscustomobject]@{ Pid = [int]$_.ProcessId; ParentPid = [int]$_.ParentProcessId; Start = (ConvertTo-RgStamp $_.CreationDate)
                Name = ([string]$_.Name -replace '\.exe$', '').ToLowerInvariant(); Cmd = [string]$_.CommandLine }
        })
    $kids = @{}
    foreach ($p in $all) {
        if (-not $kids.ContainsKey($p.ParentPid)) { $kids[$p.ParentPid] = New-Object System.Collections.ArrayList }
        [void]$kids[$p.ParentPid].Add($p)
    }
    $out = New-Object System.Collections.ArrayList
    $seen = @{ $RootPid = $true }
    $q = New-Object System.Collections.Queue
    $q.Enqueue([pscustomobject]@{ Pid = $RootPid; Start = $RootStart; Depth = 0 })
    while ($q.Count -gt 0) {
        $cur = $q.Dequeue()
        if ($cur.Depth -ge 8 -or -not $kids.ContainsKey([int]$cur.Pid)) { continue }
        foreach ($k in $kids[[int]$cur.Pid]) {
            if ($seen.ContainsKey($k.Pid) -or $k.Pid -eq 0) { continue }
            if ($cur.Start -and $k.Start -and $k.Start -lt $cur.Start) { continue }
            $seen[$k.Pid] = $true
            [void]$out.Add($k)
            $q.Enqueue([pscustomobject]@{ Pid = $k.Pid; Start = $k.Start; Depth = $cur.Depth + 1 })
        }
    }
    $arr = @($out.ToArray()); [array]::Reverse($arr)
    return $arr
}

function Stop-RgProcessVerified {
    param([int]$ProcId, [string]$Start, [string]$Name, [int]$GraceSec = 5, [bool]$IncludeTree = $true, $Cfg = $null)
    $res = [ordered]@{ ok = $false; method = 'none'; exited = $false; reason = ''; tree = @(); skipped = @() }
    if ($ProcId -eq $PID) { $res.reason = 'refusing to stop the guard itself'; return [pscustomobject]$res }
    if (-not (Test-RgProcessIdentity $ProcId $Start $Name)) { $res.reason = 'PID is gone or was reused (start time / name mismatch)'; return [pscustomobject]$res }
    if (-not $Cfg) { $Cfg = Get-RgConfig }

    $kids = @(); $skipped = @()
    if ($IncludeTree) {
        foreach ($k in @(Get-RgProcessTree $ProcId $Start)) {
            $g = Get-RgGroup ([string]$k.Name) ([string]$k.Cmd) $Cfg
            if ($k.Pid -ne $PID -and @($Cfg.kill.allowedGroups) -contains $g) { $kids += $k }
            else { $skipped += [pscustomobject]@{ pid = $k.Pid; name = $k.Name; group = $g } }
        }
    }
    $res.skipped = @($skipped)

    # 1) đóng êm: chỉ có ý nghĩa với tiến trình có cửa sổ
    $method = 'forced'
    if ($GraceSec -gt 0) {
        $proc = $null
        try { $proc = Get-Process -Id $ProcId -ErrorAction Stop } catch { }
        if ($proc) {
            try {
                if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and $proc.CloseMainWindow()) {
                    $until = (Get-Date).AddSeconds($GraceSec)
                    while ((Get-Date) -lt $until -and (Test-RgProcessIdentity $ProcId $Start $Name)) { Start-Sleep -Milliseconds 200 }
                    if (-not (Test-RgProcessIdentity $ProcId $Start $Name)) { $method = 'graceful' }
                }
            } catch { } finally { $proc.Dispose() }
        }
    }

    # 2) buộc dừng: hậu duệ (lá trước) rồi gốc, mỗi lần đều kiểm lại danh tính ngay trước khi tác động
    $targets = @($kids | ForEach-Object { [pscustomobject]@{ pid = $_.Pid; start = $_.Start; name = $_.Name } })
    $targets += [pscustomobject]@{ pid = $ProcId; start = $Start; name = $Name }
    foreach ($t in $targets) {
        if (-not (Test-RgProcessIdentity ([int]$t.pid) ([string]$t.start) ([string]$t.name))) { continue }   # đã thoát (hoặc PID đã đổi chủ)
        try { Stop-Process -Id ([int]$t.pid) -Force -ErrorAction Stop } catch { }
    }

    # 3) xác minh thoát (chờ tối đa ~5 giây)
    $deadline = (Get-Date).AddSeconds(5)
    $treeOut = @()
    foreach ($t in $targets) {
        while ((Test-RgProcessIdentity ([int]$t.pid) ([string]$t.start) ([string]$t.name)) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $gone = -not (Test-RgProcessIdentity ([int]$t.pid) ([string]$t.start) ([string]$t.name))
        $treeOut += [pscustomobject]@{ pid = $t.pid; name = $t.name; exited = $gone }
    }
    $rootGone = [bool]($treeOut | Where-Object { $_.pid -eq $ProcId } | Select-Object -First 1).exited
    $res.tree = @($treeOut); $res.exited = $rootGone
    $res.ok = ($rootGone -and @($treeOut | Where-Object { -not $_.exited }).Count -eq 0)
    $res.method = if ($rootGone) { $method } else { 'none' }
    if (-not $res.ok) { $res.reason = if (-not $rootGone) { 'process did not exit after stop request' } else { 'some child processes did not exit' } }
    return [pscustomobject]$res
}

# ---------- Process ledger (process do agent tạo ra) ----------

function Get-RgLedgerPath { return (Join-Path (Initialize-RgHome) 'state\process-ledger.json') }

function Read-RgLedger {
    $p = Get-RgLedgerPath
    if (Test-Path -LiteralPath $p) {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) { return @(ConvertFrom-Json $raw | ForEach-Object { $_ }) }   # ForEach-Object: PS 5.1 không tự bung mảng JSON
    }
    return @()
}

function Write-RgLedger($Entries) {
    Write-RgFileAtomic (Get-RgLedgerPath) (ConvertTo-Json -InputObject @($Entries) -Depth 5)
}

# Đọc-sửa-ghi ledger phải đi qua khoá chung (nhiều agent đăng ký cùng lúc không được ghi đè nhau).
function Invoke-RgLedgerLocked([scriptblock]$Body) {
    $m = New-Object Threading.Mutex($false, 'Local\ResourceGuardLedger')
    $held = $false
    try {
        try { $held = $m.WaitOne(8000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Ledger is locked by another process (timeout).' }
        return (& $Body)
    } finally {
        if ($held) { try { $m.ReleaseMutex() } catch { } }
        $m.Dispose()
    }
}

# Hạn đăng ký (TTL): mục ledger mà process chủ đã chết và không được làm mới (heartbeat) quá ttlHours thì hết hiệu lực —
# process đó có thể nay đã là việc của người dùng, không còn đủ điều kiện để kết thúc theo ledger.
function Get-RgLedgerTtlHours($Cfg) {
    $h = 24.0
    try { if ($Cfg -and $Cfg.PSObject.Properties['ledger'] -and $Cfg.ledger -and $Cfg.ledger.PSObject.Properties['ttlHours'] -and [double]$Cfg.ledger.ttlHours -gt 0) { $h = [double]$Cfg.ledger.ttlHours } } catch { }
    return $h
}

function Test-RgLedgerEntryExpired($Entry, $Cfg) {
    $cut = ConvertTo-RgStamp ((Get-Date).AddHours(-(Get-RgLedgerTtlHours $Cfg)))
    $last = [string]$Entry.registeredUtc
    if ($Entry.PSObject.Properties['lastSeenUtc'] -and $Entry.lastSeenUtc -and [string]$Entry.lastSeenUtc -gt $last) { $last = [string]$Entry.lastSeenUtc }
    if (-not $last) { return $false }
    if ($last -ge $cut) { return $false }
    # chủ còn sống thì chưa hết hạn: phiên agent dài vẫn đang sở hữu process này
    if ($Entry.ownerStart -and (Test-RgProcessIdentity ([int]$Entry.ownerPid) ([string]$Entry.ownerStart) '')) { return $false }
    return $true
}

# Làm mới lastSeenUtc (agent còn sống gọi định kỳ). Trả $true nếu tìm thấy mục.
function Update-RgLedgerHeartbeat([int]$ProcId, [string]$Start = '') {
    return [bool](Invoke-RgLedgerLocked {
            $found = $false
            $all = @(Read-RgLedger)
            foreach ($e in $all) {
                if ([int]$e.pid -eq $ProcId -and (-not $Start -or [string]$e.start -eq $Start)) {
                    $e | Add-Member -NotePropertyName lastSeenUtc -NotePropertyValue (Get-RgNowStamp) -Force
                    $found = $true
                }
            }
            if ($found) { Write-RgLedger $all }
            $found
        })
}

function Register-RgProcess {
    param([int]$ProcId, [string]$Agent = 'unknown', [string]$Label = '', [int]$OwnerPid = 0)
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
    if (-not $c) { throw "Process $ProcId not found." }
    if (-not $OwnerPid) { $OwnerPid = [int]$c.ParentProcessId }
    $o = Get-CimInstance Win32_Process -Filter "ProcessId=$OwnerPid" -ErrorAction SilentlyContinue
    $ownerStart = $null
    if ($o) { $ownerStart = ConvertTo-RgStamp $o.CreationDate }
    $entry = [ordered]@{
        pid           = $ProcId
        start         = (ConvertTo-RgStamp $c.CreationDate)
        name          = ([string]$c.Name -replace '\.exe$', '').ToLowerInvariant()
        agent         = $Agent
        label         = $Label
        ownerPid      = $OwnerPid
        ownerStart    = $ownerStart
        registeredUtc = (Get-RgNowStamp)
        lastSeenUtc   = (Get-RgNowStamp)
    }
    Invoke-RgLedgerLocked {
        $keep = @(Read-RgLedger | Where-Object {
                -not ($_.pid -eq $entry.pid -and $_.start -eq $entry.start) -and
                (Test-RgProcessIdentity ([int]$_.pid) ([string]$_.start) ([string]$_.name))
            })
        Write-RgLedger ($keep + [pscustomobject]$entry)
    } | Out-Null
    Write-RgLog 'register' $entry
    return [pscustomobject]$entry
}

# Process trong ledger còn sống nhưng process sở hữu (agent) đã chết => orphan chắc chắn của agent.
# Mục đã hết hạn (Test-RgLedgerEntryExpired) không còn được coi là của agent.
function Get-RgLedgerOrphans {
    $out = @()
    $cfg = $null; try { $cfg = Get-RgConfig } catch { }
    foreach ($e in (Read-RgLedger)) {
        $alive = Test-RgProcessIdentity ([int]$e.pid) ([string]$e.start) ([string]$e.name)
        if (-not $alive) { continue }
        if (Test-RgLedgerEntryExpired $e $cfg) { continue }
        $ownerAlive = $false
        if ($e.ownerStart) { $ownerAlive = [bool](Test-RgProcessIdentity ([int]$e.ownerPid) ([string]$e.ownerStart) '') }
        if (-not $ownerAlive) { $out += $e }
    }
    return $out
}

# ---------- Lease phiên agent, giữ chỗ preflight, đếm subagent (C3) ----------
# Ledger hai tầng: (1) KHAI BÁO = process-ledger.json (agent tự register) + lease phiên (hook SessionStart/SessionEnd hoặc `lease acquire`);
# (2) QUAN SÁT = hậu duệ build/test/dev của chủ lease đang sống (Get-RgObservedLedger), suy ra từ cây tiến trình, không ai khai.
# Lease có FENCING TOKEN đơn điệu tăng: nhận lease lại cho cùng sessionId (resume/compact) => token mới, mọi giữ chỗ mang token cũ mất hiệu lực,
# nên một tiến trình cũ còn sót của phiên đó không thể tiếp tục chiếm chỗ. Giữ chỗ (reservation) = "đã được preflight cho phép, chưa chắc đã chạy":
# RAM/slot heavy chỉ tính trong cửa sổ warmup (sau đó snapshot thật đã thấy), còn subagent (không có process riêng) tính tới khi SubagentStop/TTL.
# Hook không bao giờ lưu prompt, nội dung trả lời hay transcript: chỉ session_id, cwd, tên tool, tên tác vụ.

function Get-RgLeaseCfg($Cfg) {
    $o = [ordered]@{ ttlMin = 180.0; reserveTtlMin = 10.0; subagentTtlMin = 30.0; warmupSec = 90.0; deferMaxSec = 20.0; lastKnownMaxAgeMin = 30.0; agentProcessNames = @('claude', 'codex', 'node') }
    try {
        if ($Cfg -and $Cfg.PSObject.Properties['lease'] -and $Cfg.lease) {
            foreach ($k in @('ttlMin', 'reserveTtlMin', 'subagentTtlMin', 'warmupSec', 'deferMaxSec', 'lastKnownMaxAgeMin')) {
                $p = $Cfg.lease.PSObject.Properties[$k]
                if ($p -and $null -ne $p.Value -and [double]$p.Value -ge 0) { $o[$k] = [double]$p.Value }
            }
            $p = $Cfg.lease.PSObject.Properties['agentProcessNames']
            if ($p -and $p.Value) { $o.agentProcessNames = @($p.Value | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
        }
    } catch { }
    if ($o.ttlMin -le 0) { $o.ttlMin = 180.0 }
    if ($o.reserveTtlMin -le 0) { $o.reserveTtlMin = 10.0 }
    if ($o.subagentTtlMin -le 0) { $o.subagentTtlMin = 30.0 }
    return [pscustomobject]$o
}

function Get-RgLeasePath { return (Join-Path (Initialize-RgHome) 'state\leases.json') }

function Read-RgLeaseStore {
    $s = [ordered]@{ counter = 0L; leases = @(); reservations = @() }
    $p = Get-RgLeasePath
    if (Test-Path -LiteralPath $p) {
        try {
            $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $j = ConvertFrom-Json $raw
                if ($j.PSObject.Properties['counter'] -and $null -ne $j.counter) { $s.counter = [long]$j.counter }
                $s.leases = @($j.leases | ForEach-Object { $_ } | Where-Object { $_ })
                $s.reservations = @($j.reservations | ForEach-Object { $_ } | Where-Object { $_ })
            }
        } catch { Write-RgLog 'lease-store-error' @{ error = [string]$_.Exception.Message } }   # file hỏng: bắt đầu lại; token vẫn đơn điệu nhờ đồng hồ (Get-RgNextLeaseToken)
    }
    return $s
}

function Save-RgLeaseStore($Store) {
    Write-RgFileAtomic (Get-RgLeasePath) (ConvertTo-Json -InputObject $Store -Depth 6)
}

# Đọc-sửa-ghi lease/giữ chỗ phải đi qua khoá chung (nhiều hook chạy song song, ví dụ nhiều subagent cùng lúc).
function Invoke-RgLeaseLocked([scriptblock]$Body) {
    $m = New-Object Threading.Mutex($false, 'Local\ResourceGuardLease')
    $held = $false
    try {
        try { $held = $m.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Lease store is locked by another process (timeout).' }
        return (& $Body)
    } finally {
        if ($held) { try { $m.ReleaseMutex() } catch { } }
        $m.Dispose()
    }
}

# Token đơn điệu: lớn hơn mọi token đã cấp, và (nhờ đồng hồ) vẫn lớn hơn dù file lease bị mất/hỏng giữa chừng.
function Get-RgNextLeaseToken([long]$Counter) {
    $now = [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds
    return [long][math]::Max($Counter + 1L, $now)
}

function Test-RgLeaseExpired($Lease, $Cfg) {
    $c = Get-RgLeaseCfg $Cfg
    $last = [string]$Lease.lastSeenUtc; if (-not $last) { $last = [string]$Lease.acquiredUtc }
    if (-not $last) { return $true }
    if ($last -ge (ConvertTo-RgStamp ((Get-Date).AddMinutes(-$c.ttlMin)))) { return $false }
    if ([int]$Lease.ownerPid -gt 0 -and $Lease.ownerStart -and (Test-RgProcessIdentity ([int]$Lease.ownerPid) ([string]$Lease.ownerStart) '')) { return $false }   # chủ còn sống: phiên dài vẫn đang giữ lease
    return $true
}

# Bỏ lease hết hạn và mọi giữ chỗ mồ côi/hết hạn. Hàm thuần trên $Store (trả store mới, không ghi file).
function Invoke-RgLeasePrune($Store, $Cfg) {
    $leases = @($Store.leases | Where-Object { -not (Test-RgLeaseExpired $_ $Cfg) })
    $tok = @{}; foreach ($l in $leases) { $tok[[string]$l.sessionId] = [long]$l.token }
    $now = Get-RgNowStamp
    $res = @($Store.reservations | Where-Object {
            if ([string]$_.expiresUtc -lt $now) { return $false }
            $sid = [string]$_.sessionId
            if (-not $sid) { return $true }
            return ($tok.ContainsKey($sid) -and $tok[$sid] -eq [long]$_.token)   # fencing: lease đã bị thay/xoá => giữ chỗ vô hiệu
        })
    $Store.leases = @($leases); $Store.reservations = @($res)
    return $Store
}

function New-RgLease {
    param([string]$SessionId, [string]$Agent = 'claude', [int]$OwnerPid = 0, [string]$Cwd = '', [string]$Source = 'hook')
    if (-not $SessionId) { throw 'SessionId is required.' }
    $cfg = Get-RgConfig
    return (Invoke-RgLeaseLocked {
            $s = Invoke-RgLeasePrune (Read-RgLeaseStore) $cfg
            $ownerStart = $null
            if ($OwnerPid -gt 0) { $o = Get-CimInstance Win32_Process -Filter "ProcessId=$OwnerPid" -ErrorAction SilentlyContinue; if ($o) { $ownerStart = ConvertTo-RgStamp $o.CreationDate } }
            $token = Get-RgNextLeaseToken ([long]$s.counter)
            $lease = [pscustomobject][ordered]@{ sessionId = $SessionId; agent = $Agent; token = $token; ownerPid = $OwnerPid; ownerStart = $ownerStart
                cwd = $Cwd; source = $Source; acquiredUtc = (Get-RgNowStamp); lastSeenUtc = (Get-RgNowStamp) }
            $s.leases = @(@($s.leases | Where-Object { [string]$_.sessionId -ne $SessionId }) + $lease)
            $s.reservations = @($s.reservations | Where-Object { [string]$_.sessionId -ne $SessionId })   # nhận lại lease: giữ chỗ của token cũ hết hiệu lực
            $s.counter = $token
            Save-RgLeaseStore $s
            Write-RgLog 'lease-acquired' ([ordered]@{ sessionId = $SessionId; agent = $Agent; token = $token; ownerPid = $OwnerPid; source = $Source })
            $lease
        })
}

# Trả { ok; reason = ''|no-lease|stale-token }. Token = $null: không kiểm fencing (hook tự tra theo session_id).
function Update-RgLeaseHeartbeat {
    param([string]$SessionId, $Token = $null)
    return (Invoke-RgLeaseLocked {
            $s = Read-RgLeaseStore
            $l = @($s.leases | Where-Object { [string]$_.sessionId -eq $SessionId }) | Select-Object -First 1
            if (-not $l) { return [pscustomobject]@{ ok = $false; reason = 'no-lease' } }
            if ($null -ne $Token -and [long]$Token -ne [long]$l.token) { return [pscustomobject]@{ ok = $false; reason = 'stale-token' } }
            $l.lastSeenUtc = (Get-RgNowStamp)
            Save-RgLeaseStore $s
            [pscustomobject]@{ ok = $true; reason = '' }
        })
}

function Remove-RgLease {
    param([string]$SessionId, $Token = $null)
    return (Invoke-RgLeaseLocked {
            $s = Read-RgLeaseStore
            $l = @($s.leases | Where-Object { [string]$_.sessionId -eq $SessionId }) | Select-Object -First 1
            if (-not $l) { return [pscustomobject]@{ ok = $false; reason = 'no-lease' } }
            if ($null -ne $Token -and [long]$Token -ne [long]$l.token) { return [pscustomobject]@{ ok = $false; reason = 'stale-token' } }
            $s.leases = @($s.leases | Where-Object { [string]$_.sessionId -ne $SessionId })
            $s.reservations = @($s.reservations | Where-Object { [string]$_.sessionId -ne $SessionId })
            Save-RgLeaseStore $s
            Write-RgLog 'lease-released' ([ordered]@{ sessionId = $SessionId; token = [long]$l.token })
            [pscustomobject]@{ ok = $true; reason = '' }
        })
}

# Lease đang hiệu lực (chủ còn sống hoặc còn trong TTL), kèm số giữ chỗ/subagent của từng phiên. Chỉ đọc.
function Get-RgLeases($Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $s = Invoke-RgLeasePrune (Read-RgLeaseStore) $Cfg
    $out = @()
    foreach ($l in @($s.leases)) {
        $mine = @($s.reservations | Where-Object { [string]$_.sessionId -eq [string]$l.sessionId })
        $out += [pscustomobject][ordered]@{ sessionId = [string]$l.sessionId; agent = [string]$l.agent; token = [long]$l.token; ownerPid = [int]$l.ownerPid; ownerStart = [string]$l.ownerStart
            cwd = [string]$l.cwd; source = [string]$l.source; acquiredUtc = [string]$l.acquiredUtc; lastSeenUtc = [string]$l.lastSeenUtc
            reservations = $mine.Count; subagents = @($mine | Where-Object { [string]$_.task -eq 'subagent' }).Count }
    }
    return $out
}

function Get-RgReservations($Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    return @((Invoke-RgLeasePrune (Read-RgLeaseStore) $Cfg).reservations)
}

# Giữ chỗ thuộc về một preflight đã xong. Trả số giữ chỗ đã gỡ. Ưu tiên theo ToolUseId; không có thì gỡ cái CŨ NHẤT của phiên với tác vụ đó.
function Remove-RgReservation {
    param([string]$SessionId, [string]$Task = '', [string]$ToolUseId = '')
    return [int](Invoke-RgLeaseLocked {
            $s = Read-RgLeaseStore
            $mine = @($s.reservations | Where-Object { [string]$_.sessionId -eq $SessionId -and (-not $Task -or [string]$_.task -eq $Task) })
            if ($mine.Count -eq 0) { return 0 }
            $pick = $null
            if ($ToolUseId) { $pick = @($mine | Where-Object { [string]$_.toolUseId -eq $ToolUseId }) | Select-Object -First 1 }
            if (-not $pick) { $pick = @($mine | Sort-Object { [string]$_.createdUtc }) | Select-Object -First 1 }
            $s.reservations = @($s.reservations | Where-Object { [string]$_.id -ne [string]$pick.id })
            Save-RgLeaseStore $s
            1
        })
}

# Lần đọc cuối của trạng thái máy do server/watcher ghi (state\live.json), nếu còn đủ mới. Trả { state; ageMin } hoặc $null.
function Get-RgLastKnownState($Cfg) {
    try {
        $p = Join-Path (Initialize-RgHome) 'state\live.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $j = ConvertFrom-Json (Get-Content -LiteralPath $p -Raw -Encoding UTF8)
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$j.ts, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$t)) { return $null }
        $age = ((Get-Date) - $t).TotalMinutes
        if ($age -gt (Get-RgLeaseCfg $Cfg).lastKnownMaxAgeMin -or $age -lt -5) { return $null }
        $st = [string]$j.state
        if ($script:RgStates -notcontains $st) { return $null }
        return [pscustomobject]@{ state = $st; ageMin = [math]::Round($age, 1) }
    } catch { return $null }
}

# Chính sách khi KHÔNG đo được trạng thái máy (docs §9, chốt 2026-11-11): build/test chạy tiếp và ghi cảnh báo; subagent bị chặn khi Nguy cấp,
# hoãn (chờ rồi hỏi lại) khi Hạn chế. Trạng thái lấy từ lần đo gần nhất còn mới; không có thì không có căn cứ để chặn => cho chạy, ghi cảnh báo.
function Get-RgNoResponseDecision([string]$Task, $Cfg) {
    $lk = Get-RgLastKnownState $Cfg
    $state = if ($lk) { $lk.state } else { 'Unknown' }
    $decision = 'allow'
    $why = 'Resource Guard không đo được trạng thái máy lúc này'
    if ($Task -eq 'subagent' -and $lk) {
        if ($state -eq 'Critical') { $decision = 'deny' }
        elseif ($state -eq 'Restricted') { $decision = 'defer' }
    }
    $reasons = @("no answer from the resource check ($(if ($lk) { "last known state $state, $($lk.ageMin) min old" } else { 'no recent state' })): task '$Task' -> $decision")
    return [pscustomobject][ordered]@{ task = $Task; decision = $decision; state = $state; reasons = $reasons; source = $(if ($lk) { 'last-known' } else { 'none' }); noAnswer = $true
        warning = $(if ($decision -eq 'allow') { "$why; cho phép '$Task' chạy tiếp." } else { "$why; trạng thái gần nhất là $state nên '$Task' bị $(if ($decision -eq 'deny') { 'chặn' } else { 'hoãn' })." }); reservationId = $null }
}

# Preflight có giữ chỗ. Đo snapshot NGOÀI khoá (chậm), rồi trong khoá: đọc giữ chỗ còn hiệu lực -> ra quyết định -> ghi giữ chỗ mới (nếu -Reserve
# và không bị từ chối), nên hai preflight đồng thời không cùng thấy một phần RAM trống. SnapshotProvider (test): trả { snapshot; table }.
function Invoke-RgPreflight {
    param([string]$Task = 'session', [string]$SessionId = '', [switch]$Reserve, [string]$ToolUseId = '', [scriptblock]$SnapshotProvider = $null)
    $cfg = Get-RgConfig
    $snap = $null; $table = $null
    try {
        if ($SnapshotProvider) { $sp = & $SnapshotProvider; $snap = $sp.snapshot; $table = $sp.table }
        else { $snap = Get-RgSnapshot; $table = Get-RgProcessTable }
        if ($null -eq $snap) { throw 'empty snapshot' }
    } catch {
        $d = Get-RgNoResponseDecision $Task $cfg
        Write-RgLog 'preflight-no-answer' ([ordered]@{ task = $Task; error = [string]$_.Exception.Message; decision = $d.decision; state = $d.state })
        return $d
    }
    $lc = Get-RgLeaseCfg $cfg
    return (Invoke-RgLeaseLocked {
            $s = Invoke-RgLeasePrune (Read-RgLeaseStore) $cfg
            $warmCut = ConvertTo-RgStamp ((Get-Date).AddSeconds(-$lc.warmupSec))
            $gb = 0.0; $heavyN = 0; $subs = 0
            foreach ($r in @($s.reservations)) {
                if ([string]$r.task -eq 'subagent') { $subs++ }
                if ([string]$r.createdUtc -ge $warmCut) { $gb += [double]$r.estimateGB; if ([bool]$r.heavy) { $heavyN++ } }   # sau warmup, snapshot thật đã thấy tác vụ đó
            }
            $b = Get-RgBudget -Task $Task -Snapshot $snap -Table $table -ReservedGB $gb -ReservedHeavy $heavyN -SubagentsRunning $subs
            Add-Member -InputObject $b -NotePropertyName source -NotePropertyValue 'live' -Force
            Add-Member -InputObject $b -NotePropertyName reservationId -NotePropertyValue $null -Force
            Add-Member -InputObject $b -NotePropertyName warning -NotePropertyValue '' -Force
            if ($Reserve -and $b.decision -ne 'deny') {
                $sid = $SessionId
                $lease = $null
                if ($sid) {
                    $lease = @($s.leases | Where-Object { [string]$_.sessionId -eq $sid }) | Select-Object -First 1
                    if (-not $lease) {   # hook SessionStart chưa chạy/chưa cài: lập lease ngầm để giữ chỗ có token
                        $token = Get-RgNextLeaseToken ([long]$s.counter)
                        $lease = [pscustomobject][ordered]@{ sessionId = $sid; agent = 'unknown'; token = $token; ownerPid = 0; ownerStart = $null; cwd = ''; source = 'implicit'; acquiredUtc = (Get-RgNowStamp); lastSeenUtc = (Get-RgNowStamp) }
                        $s.leases = @(@($s.leases) + $lease); $s.counter = $token
                    } else { $lease.lastSeenUtc = (Get-RgNowStamp) }
                }
                $est = 0.0; if ($cfg.estimateGB.PSObject.Properties[$Task]) { $est = [double]$cfg.estimateGB.$Task }
                $ttl = if ($Task -eq 'subagent') { $lc.subagentTtlMin } else { $lc.reserveTtlMin }
                $id = (New-RgActionId)
                $rec = [pscustomobject][ordered]@{ id = $id; sessionId = $sid; token = $(if ($lease) { [long]$lease.token } else { 0L }); task = $Task; estimateGB = $est
                    heavy = ($Task -eq 'build' -or $Task -eq 'test'); toolUseId = $ToolUseId; createdUtc = (Get-RgNowStamp); expiresUtc = (ConvertTo-RgStamp ((Get-Date).AddMinutes($ttl))) }
                $s.reservations = @(@($s.reservations) + $rec)
                Save-RgLeaseStore $s
                $b.reservationId = $id
            }
            $b
        })
}

# Tác vụ nặng suy ra từ một dòng lệnh shell ('' nếu không phải build/test quen thuộc). Test thắng build (vd. "dotnet test" cũng build).
function Get-RgTaskFromCommand([string]$Cmd) {
    if (-not $Cmd) { return '' }
    if ($Cmd -match '(?i)\b(dotnet\s+test|(npm|pnpm|yarn)\s+(run\s+)?test|pytest|jest|vitest|cargo\s+test|mvn\s+test|gradlew?(\.bat)?\s+test|go\s+test)\b') { return 'test' }
    if ($Cmd -match '(?i)\b(dotnet\s+(build|publish|msbuild)|msbuild(\.exe)?|(npm|pnpm|yarn)\s+(run\s+)?build|cargo\s+build|mvn\s+(package|compile|install)|gradlew?(\.bat)?\s+(build|assemble)|go\s+build)\b') { return 'build' }
    return ''
}

# Process chủ của phiên agent: tổ tiên GẦN NHẤT của hook có tên trong lease.agentProcessNames (claude/codex/node); không có thì tổ tiên đầu tiên không phải shell.
function Find-RgAgentOwnerPid($Cfg = $null) {
    try {
        if (-not $Cfg) { $Cfg = Get-RgConfig }
        $names = @((Get-RgLeaseCfg $Cfg).agentProcessNames)
        $by = @{}
        foreach ($p in (Get-CimInstance Win32_Process)) { $by[[int]$p.ProcessId] = $p }
        $shells = @('powershell', 'pwsh', 'cmd', 'conhost', 'bash', 'sh', 'wsl')
        $cur = $by[[int]$PID]; $fallback = 0
        for ($i = 0; $i -lt 8 -and $cur; $i++) {
            $pp = [int]$cur.ParentProcessId
            if ($pp -le 4 -or -not $by.ContainsKey($pp)) { break }
            $cur = $by[$pp]
            $n = ([string]$cur.Name -replace '\.exe$', '').ToLowerInvariant()
            if ($names -contains $n) { return [int]$cur.ProcessId }
            if (-not $fallback -and $shells -notcontains $n) { $fallback = [int]$cur.ProcessId }
        }
        return $fallback
    } catch { return 0 }
}

# Xử lý MỘT sự kiện hook của Claude Code. Payload = JSON từ stdin. Trả { ok; event; action; block; message }.
# block = $true => script hook thoát mã 2 (Claude Code chặn tool và đưa message cho model). Mọi lỗi nội bộ KHÔNG được làm hỏng phiên của người dùng:
# nơi gọi (rg-hook.ps1) bắt lỗi và thoát 0.
function Invoke-RgHookEvent {
    param($Payload, [string]$Agent = 'claude', [int]$OwnerPid = 0, [scriptblock]$SnapshotProvider = $null)
    $ev = [string]$Payload.hook_event_name; $sid = [string]$Payload.session_id
    $res = [ordered]@{ ok = $true; event = $ev; action = 'ignored'; block = $false; message = '' }
    if (-not $sid) { $res.action = 'no-session'; return [pscustomobject]$res }
    $cfg = Get-RgConfig
    $ensure = { if (-not (Update-RgLeaseHeartbeat -SessionId $sid).ok) { [void](New-RgLease -SessionId $sid -Agent $Agent -OwnerPid $(if ($OwnerPid) { $OwnerPid } else { Find-RgAgentOwnerPid $cfg }) -Cwd ([string]$Payload.cwd) -Source 'implicit') } }
    switch ($ev) {
        'SessionStart' {
            $own = if ($OwnerPid) { $OwnerPid } else { Find-RgAgentOwnerPid $cfg }
            $l = New-RgLease -SessionId $sid -Agent $Agent -OwnerPid $own -Cwd ([string]$Payload.cwd) -Source ('hook:' + [string]$Payload.source)
            $res.action = 'lease-acquired'; $res.token = $l.token
        }
        { @('UserPromptSubmit', 'Stop') -contains $_ } { & $ensure; $res.action = 'heartbeat' }
        'SessionEnd' { $r = Remove-RgLease -SessionId $sid; $res.action = $(if ($r.ok) { 'lease-released' } else { 'no-lease' }) }
        'SubagentStop' {
            $n = Remove-RgReservation -SessionId $sid -Task 'subagent'
            [void](Update-RgLeaseHeartbeat -SessionId $sid)
            $res.action = $(if ($n -gt 0) { 'subagent-released' } else { 'subagent-untracked' })
        }
        'PostToolUse' {
            $task = Get-RgTaskFromCommand ([string]$Payload.tool_input.command)
            if (@('Bash', 'PowerShell') -contains [string]$Payload.tool_name -and $task) {
                $n = Remove-RgReservation -SessionId $sid -Task $task -ToolUseId ([string]$Payload.tool_use_id)
                $res.action = $(if ($n -gt 0) { 'reservation-released' } else { 'ignored' })
            }
        }
        'PreToolUse' {
            $tool = [string]$Payload.tool_name; $task = ''
            if (@('Task', 'Agent') -contains $tool) { $task = 'subagent' }
            elseif (@('Bash', 'PowerShell') -contains $tool) { $task = Get-RgTaskFromCommand ([string]$Payload.tool_input.command) }
            if (-not $task) { break }
            & $ensure
            $pf = Invoke-RgPreflight -Task $task -SessionId $sid -Reserve -ToolUseId ([string]$Payload.tool_use_id) -SnapshotProvider $SnapshotProvider
            if ($pf.decision -eq 'defer') {   # hoãn: chờ máy bớt chật trong giới hạn rồi hỏi lại; hết hạn mà vẫn chật thì chặn
                $until = (Get-Date).AddSeconds((Get-RgLeaseCfg $cfg).deferMaxSec)
                while ($pf.decision -eq 'defer' -and (Get-Date) -lt $until) { Start-Sleep -Seconds 3; $pf = Invoke-RgPreflight -Task $task -SessionId $sid -Reserve -ToolUseId ([string]$Payload.tool_use_id) -SnapshotProvider $SnapshotProvider }
                if ($pf.decision -eq 'defer') { $pf = [pscustomobject]@{ decision = 'deny'; reasons = @($pf.reasons) + 'still restricted after waiting'; warning = '' } }
            }
            $res.action = "preflight:$task=$($pf.decision)"
            if ($pf.decision -eq 'deny') {
                $res.block = $true
                $res.message = "Resource Guard: chưa nên chạy '$task' lúc này ($(@($pf.reasons) -join '; ')). Hãy chờ hoặc giải phóng bộ nhớ/đĩa rồi thử lại."
            } elseif ($pf.warning) { $res.warning = [string]$pf.warning }
        }
        default { }
    }
    return [pscustomobject]$res
}

# Chữ trong ~/.claude/settings.json để bật hook. CHỈ IN, không bao giờ tự sửa file settings của người dùng.
function Get-RgHooksSnippet([string]$Root, [switch]$Heavy) {
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Root 'scripts\rg-hook.ps1') + '"'
    $h = { param($timeout) @{ hooks = @(@{ type = 'command'; command = $cmd; timeout = $timeout }) } }
    $pre = @((@{ matcher = 'Task|Agent'; hooks = (& $h 45).hooks }))
    $hooks = [ordered]@{
        SessionStart = @(& $h 15); SessionEnd = @(& $h 15); Stop = @(& $h 15); SubagentStop = @(& $h 15); PreToolUse = $pre
    }
    if ($Heavy) {
        $hooks.PreToolUse = @($pre + @{ matcher = 'Bash|PowerShell'; hooks = (& $h 45).hooks })
        $hooks.PostToolUse = @(@{ matcher = 'Bash|PowerShell'; hooks = (& $h 15).hooks })
    }
    return (ConvertTo-Json -InputObject ([ordered]@{ hooks = $hooks }) -Depth 8)
}

# Tầng QUAN SÁT của ledger: hậu duệ build/test/dev của chủ lease đang sống. Không ai khai báo, chỉ suy từ cây tiến trình.
# Trả [{ pid; start; name; group; sessionId; agent; source = 'observed' }].
function Get-RgObservedLedger {
    param($Table = $null, $Cfg = $null, $Leases = $null)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Leases) { $Leases = @(Get-RgLeases $Cfg) }
    $Leases = @($Leases | Where-Object { [int]$_.ownerPid -gt 0 -and $_.ownerStart })
    if ($Leases.Count -eq 0) { return @() }
    if ($null -eq $Table) { $Table = @(Get-RgProcessTable) }
    $kids = @{}; $byPid = @{}
    foreach ($p in $Table) {
        $byPid[[int]$p.Pid] = $p
        if (-not $kids.ContainsKey([int]$p.ParentPid)) { $kids[[int]$p.ParentPid] = New-Object System.Collections.ArrayList }
        [void]$kids[[int]$p.ParentPid].Add($p)
    }
    $out = @(); $seen = @{}
    foreach ($l in $Leases) {
        $root = $byPid[[int]$l.ownerPid]
        if (-not $root -or [string]$root.Start -ne [string]$l.ownerStart) { continue }   # chủ đã chết hoặc PID bị tái sử dụng
        $q = New-Object System.Collections.Queue; $q.Enqueue(@($root, 0))
        while ($q.Count -gt 0) {
            $it = $q.Dequeue(); $cur = $it[0]; $d = [int]$it[1]
            if ($d -ge 8 -or -not $kids.ContainsKey([int]$cur.Pid)) { continue }
            foreach ($k in $kids[[int]$cur.Pid]) {
                if ($seen.ContainsKey([int]$k.Pid) -or [int]$k.Pid -eq 0) { continue }
                if ($cur.Start -and $k.Start -and [string]$k.Start -lt [string]$cur.Start) { continue }   # con "cũ hơn" cha: PID cha bị tái sử dụng
                $seen[[int]$k.Pid] = $true
                if (@('build', 'test', 'dev') -contains [string]$k.Group) {
                    $out += [pscustomobject][ordered]@{ pid = [int]$k.Pid; start = [string]$k.Start; name = [string]$k.Name; group = [string]$k.Group; sessionId = [string]$l.sessionId; agent = [string]$l.agent; source = 'observed' }
                }
                $q.Enqueue(@($k, ($d + 1)))
            }
        }
    }
    return $out
}

# ---------- Budget / preflight ----------

function Get-RgRamState([double]$AvailGB, $Cfg) {
    if ($AvailGB -gt [double]$Cfg.ram.normalAboveGB) { return 'Normal' }
    if ($AvailGB -ge [double]$Cfg.ram.cautionFromGB) { return 'Caution' }
    if ($AvailGB -ge [double]$Cfg.ram.restrictedFromGB) { return 'Restricted' }
    return 'Critical'
}

# Ngưỡng ổ đĩa theo từng ổ: cfg.disk.drives.<X>.{normalAboveGB,cautionFromGB} ghi đè ngưỡng chung cfg.disk.*.
function Get-RgDiskThresholds($Cfg, [string]$Drive = '') {
    $n = [double]$Cfg.disk.normalAboveGB; $c = [double]$Cfg.disk.cautionFromGB
    if ($Drive -and $Cfg.disk.drives) {
        $o = $Cfg.disk.drives.PSObject.Properties[$Drive.ToUpperInvariant()]
        if ($o -and $o.Value) {
            if ($null -ne $o.Value.normalAboveGB) { $n = [double]$o.Value.normalAboveGB }
            if ($null -ne $o.Value.cautionFromGB) { $c = [double]$o.Value.cautionFromGB }
        }
    }
    return [pscustomobject]@{ normalAboveGB = $n; cautionFromGB = $c }
}

function Get-RgDiskState($FreeGB, $Cfg, [string]$Drive = '') {
    if ($null -eq $FreeGB) { return 'Normal' }
    $t = Get-RgDiskThresholds $Cfg $Drive
    if ([double]$FreeGB -gt $t.normalAboveGB) { return 'Normal' }
    if ([double]$FreeGB -ge $t.cautionFromGB) { return 'Caution' }
    return 'Critical'
}

# Chữ cái ổ của một đường dẫn ('D:\x' -> 'D'); $null nếu không phải đường dẫn có ổ (UNC...).
function Get-RgPathDrive([string]$Path) {
    if ($Path -match '^([A-Za-z]):[\\/]') { return $Matches[1].ToUpperInvariant() }
    return $null
}

# Các ổ cố định đang sẵn sàng (bỏ ổ gỡ được, ổ mạng, ổ chưa sẵn sàng, và ổ trong cfg.disk.exclude).
function Get-RgDrives {
    $cfg = Get-RgConfig
    $ex = @($cfg.disk.exclude | ForEach-Object { ([string]$_).TrimEnd(':', '\').ToUpperInvariant() })
    $sys = ([string]$env:SystemDrive).TrimEnd(':', '\').ToUpperInvariant()
    $out = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
            $letter = $d.Name.Substring(0, 1).ToUpperInvariant()
            if ($ex -contains $letter) { continue }
            $label = ''; try { $label = [string]$d.VolumeLabel } catch { }
            $free = [math]::Round($d.AvailableFreeSpace / 1GB, 2)
            $out += [pscustomobject]@{
                drive = $letter; label = $label; isSystem = ($letter -eq $sys)
                totalBytes = [long]$d.TotalSize; freeBytes = [long]$d.AvailableFreeSpace
                totalGB = [math]::Round($d.TotalSize / 1GB, 1); freeGB = $free
                state = (Get-RgDiskState $free $cfg $letter)
            }
        } catch { }
    }
    return @($out | Sort-Object drive)
}

# Thư mục gốc workspace được phép quét/dọn: cleanup.workspaceRoots + (nếu cleanup.autoRoots != false) các thư mục tên quen thuộc
# (Work, Repositories, Source, Projects...) ngay dưới gốc của MỌI ổ cố định khác ổ hệ thống. Dùng chung cho quét và cho blocker xoá
# để hai bên luôn khớp. Kết quả cache 30s vì blocker gọi theo từng mục.
function Get-RgWorkspaceRoots($Cleanup) {
    if ($script:RgRootsCache -and ((Get-Date) - $script:RgRootsCacheAt).TotalSeconds -lt 30 -and $script:RgRootsCacheKey -eq ($Cleanup | ConvertTo-Json -Compress -Depth 4)) { return $script:RgRootsCache }
    $roots = New-Object System.Collections.ArrayList
    $add = { param($p) $dup = $false; foreach ($e in $roots) { if ($e -ieq $p) { $dup = $true; break } }; if (-not $dup) { [void]$roots.Add($p) } }
    foreach ($w in @($Cleanup.workspaceRoots)) { if ($w) { & $add (Expand-RgPath ([string]$w)) } }
    $auto = $true
    if ($Cleanup.PSObject.Properties['autoRoots'] -and $null -ne $Cleanup.autoRoots) { $auto = [bool]$Cleanup.autoRoots }
    if ($auto) {
        $names = @('Work', 'Repositories', 'Repos', 'Source', 'Src', 'Projects', 'Dev', 'Code', 'Workspace')
        if ($Cleanup.PSObject.Properties['autoRootNames'] -and $Cleanup.autoRootNames) { $names = @($Cleanup.autoRootNames | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notmatch '[\\/:*?"<>|]' }) }
        foreach ($d in (Get-RgDrives)) {
            if ($d.isSystem) { continue }
            foreach ($n in $names) { $p = "$($d.drive):\$n"; if (Test-Path -LiteralPath $p -PathType Container) { & $add $p } }
        }
    }
    $script:RgRootsCache = $roots.ToArray(); $script:RgRootsCacheAt = Get-Date
    $script:RgRootsCacheKey = ($Cleanup | ConvertTo-Json -Compress -Depth 4)
    return $script:RgRootsCache
}

# Ổ "chính" cho các chỗ còn dùng một số duy nhất (diskDrive/diskFreeGB): cfg.disk.drive nếu có, không thì ổ hệ thống, không thì ổ đầu.
function Get-RgPrimaryDrive($Drives, $Cfg) {
    $want = ([string]$Cfg.disk.drive).TrimEnd(':', '\').ToUpperInvariant()
    $p = @($Drives | Where-Object { $_.drive -eq $want }) | Select-Object -First 1
    if (-not $p) { $p = @($Drives | Where-Object { $_.isSystem }) | Select-Object -First 1 }
    if (-not $p) { $p = @($Drives) | Select-Object -First 1 }
    return $p
}

function Get-RgCommitState([double]$Pct, $Cfg) {
    if ($Pct -ge [double]$Cfg.commit.criticalPct) { return 'Critical' }
    if ($Pct -ge [double]$Cfg.commit.restrictedPct) { return 'Restricted' }
    return 'Normal'
}

function Get-RgWorstState([string[]]$States) {
    $max = 0
    foreach ($s in $States) { $i = [array]::IndexOf($script:RgStates, $s); if ($i -gt $max) { $max = $i } }
    return $script:RgStates[$max]
}

# Quyết định thuần deterministic. Snapshot/Table có thể truyền vào để test.
function Get-RgBudget {
    # ReservedGB/ReservedHeavy/SubagentsRunning: phần đã giữ chỗ bởi các preflight trước (C3, xem Invoke-RgPreflight); mặc định 0 = hành vi cũ.
    param([string]$Task = 'session', $Snapshot = $null, $Table = $null, [double]$ReservedGB = 0, [int]$ReservedHeavy = 0, [int]$SubagentsRunning = 0)
    $cfg = Get-RgConfig
    if ($null -eq $Snapshot) { $Snapshot = Get-RgSnapshot }
    if ($null -eq $Table) { $Table = Get-RgProcessTable }
    $reasons = New-Object System.Collections.ArrayList

    $ramState = Get-RgRamState $Snapshot.availRamGB $cfg
    # Trạng thái ổ đĩa = xấu nhất trong các ổ được giám sát (snapshot không có danh sách ổ thì dùng ổ chính như cũ).
    $driveStates = @()
    foreach ($d in @($Snapshot.drives)) { if ($d) { $driveStates += [pscustomobject]@{ drive = $d.drive; freeGB = $d.freeGB; state = (Get-RgDiskState $d.freeGB $cfg ([string]$d.drive)) } } }
    if ($driveStates.Count -eq 0) { $driveStates = @([pscustomobject]@{ drive = $Snapshot.diskDrive; freeGB = $Snapshot.diskFreeGB; state = (Get-RgDiskState $Snapshot.diskFreeGB $cfg ([string]$Snapshot.diskDrive)) }) }
    $diskState = Get-RgWorstState @($driveStates | ForEach-Object { $_.state })
    $commitState = Get-RgCommitState $Snapshot.commitPct $cfg
    if ($null -eq $Snapshot.diskFreeGB -and $driveStates.Count -le 1) { [void]$reasons.Add('disk free space unknown') }

    $est = 0.0
    if ($cfg.estimateGB.PSObject.Properties[$Task]) { $est = [double]$cfg.estimateGB.$Task }
    $projState = Get-RgRamState ($Snapshot.availRamGB - $est - $ReservedGB) $cfg
    $state = Get-RgWorstState @($ramState, $diskState, $commitState, $projState)

    if ($ramState -ne 'Normal') { [void]$reasons.Add("available RAM $($Snapshot.availRamGB)GB -> $ramState") }
    foreach ($ds in $driveStates) { if ($ds.state -ne 'Normal') { [void]$reasons.Add("disk $($ds.drive): free $($ds.freeGB)GB -> $($ds.state)") } }
    if ($commitState -ne 'Normal') { [void]$reasons.Add("commit charge $($Snapshot.commitPct)% -> $commitState") }
    if (($est -gt 0 -or $ReservedGB -gt 0) -and $projState -ne $ramState) {
        $why = if ($ReservedGB -gt 0) { "projected RAM after '$Task' (~${est}GB) and ${ReservedGB}GB reserved by earlier preflights -> $projState" } else { "projected RAM after '$Task' (~${est}GB) -> $projState" }
        [void]$reasons.Add($why)
    }

    $heavy = @(Get-RgHeavyRoots $Table $cfg)
    $heavyCount = $heavy.Count + $ReservedHeavy
    $pol = $cfg.policy.$state
    $decision = 'allow'

    if ($Task -eq 'build' -or $Task -eq 'test') {
        if ($pol.heavy -eq 'deny') {
            $decision = 'deny'
            [void]$reasons.Add("state $state blocks new heavy tasks")
        } elseif ($heavyCount -ge [int]$pol.maxHeavy) {
            $decision = 'deny'
            [void]$reasons.Add("concurrency budget reached ($heavyCount/$($pol.maxHeavy) heavy tasks running)")
        } elseif ($state -ne 'Normal') { $decision = 'warn' }
    } elseif ($Task -eq 'subagent') {
        $decision = [string]$pol.subagent
        if ($decision -eq 'deny') { [void]$reasons.Add("state $state blocks new subagents") }
        elseif ($pol.PSObject.Properties['maxSubagents'] -and $SubagentsRunning -ge [int]$pol.maxSubagents) {
            $decision = 'deny'
            [void]$reasons.Add("subagent concurrency budget reached ($SubagentsRunning/$($pol.maxSubagents) subagents running)")
        }
    } else {
        if ($state -ne 'Normal') { $decision = 'warn' }
    }

    return [pscustomobject]@{
        task         = $Task
        decision     = $decision
        state        = $state
        ramState     = $ramState
        diskState    = $diskState
        commitState  = $commitState
        availRamGB   = $Snapshot.availRamGB
        diskFreeGB   = $Snapshot.diskFreeGB
        commitPct    = $Snapshot.commitPct
        estimateGB   = $est
        heavyRunning = $heavyCount
        maxHeavy     = [int]$pol.maxHeavy
        reservedGB   = $ReservedGB
        subagentsRunning = $SubagentsRunning
        cleanupMode  = [string]$pol.cleanup
        reasons      = @($reasons)
    }
}

# ---------- Quét ứng viên cleanup ----------

function Test-RgReparse([string]$Path) {
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch { return $true }   # không đọc được => coi như không an toàn
}

function Test-RgUnderRoot([string]$Path, [string[]]$Roots) {
    foreach ($r in $Roots) {
        $rt = ($r.TrimEnd('\')) + '\'
        if ($Path.StartsWith($rt, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Tổng dung lượng + thời điểm ghi mới nhất; không đi xuyên junction/symlink.
function Get-RgDirStats([string]$Path) {
    $bytes = 0L
    $newest = [datetime]::MinValue
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object IO.DirectoryInfo($d)
            foreach ($e in $di.EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName) }
                else {
                    $bytes += $e.Length
                    if ($e.LastWriteTimeUtc -gt $newest) { $newest = $e.LastWriteTimeUtc }
                }
            }
        } catch { }
    }
    return [pscustomobject]@{ bytes = $bytes; newestUtc = $newest }
}

# Gom (hoặc xoá với -Delete) file KHÔNG hoạt động (cả ghi lẫn truy cập) quá $Days ngày. Không đi xuyên junction/symlink.
# Sau khi xoá, dọn thư mục rỗng (không bao giờ xoá thư mục gốc).
function Invoke-RgAgedFiles {
    param([string]$Path, [int]$Days, [switch]$Delete)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)
    $bytes = 0L; $count = 0; $failed = 0; $firstErr = ''
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop(); [void]$dirs.Add($d)
        try {
            foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName); continue }
                $act = $e.LastWriteTimeUtc
                if ($e.LastAccessTimeUtc -gt $act) { $act = $e.LastAccessTimeUtc }
                if ($act -ge $cutoff) { continue }
                if ($Delete) {
                    try {
                        if ($e.IsReadOnly) { $e.IsReadOnly = $false }
                        [IO.File]::Delete($e.FullName); $bytes += $e.Length; $count++
                    } catch { $failed++; if (-not $firstErr) { $firstErr = $_.Exception.Message } }
                } else { $bytes += $e.Length; $count++ }
            }
        } catch { }
    }
    if ($Delete) {
        foreach ($d in @($dirs | Sort-Object { $_.Length } -Descending)) {
            if ($d -eq $Path) { continue }
            try { [IO.Directory]::Delete($d, $false) } catch { }   # chỉ xoá được khi rỗng
        }
    }
    return [pscustomobject]@{ bytes = $bytes; count = $count; failed = $failed; firstError = $firstErr }
}

# Xoá cây thư mục theo từng mục (thay [IO.Directory]::Delete(path, $true) vốn bỏ cả cây khi gặp MỘT mục bị từ chối,
# ví dụ file 'lock' ẩn do tiến trình/tài khoản khác giữ). Không đi xuyên junction/symlink (chỉ gỡ chính link).
# Trả bytes/count đã xoá thật, failed = số mục không xoá được, removed = gốc đã biến mất.
function Remove-RgTree {
    param([string]$Path)
    $bytes = 0L; $count = 0; $failed = 0; $firstErr = ''
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop(); [void]$dirs.Add($d)
        try {
            foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
                try {
                    $isDir = $e -is [IO.DirectoryInfo]
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        if ($isDir) { [IO.Directory]::Delete($e.FullName, $false) } else { [IO.File]::Delete($e.FullName) }
                        continue
                    }
                    if ($isDir) { $stack.Push($e.FullName); continue }
                    $len = $e.Length
                    if ($e.IsReadOnly) { $e.IsReadOnly = $false }
                    [IO.File]::Delete($e.FullName); $bytes += $len; $count++
                } catch { $failed++; if (-not $firstErr) { $firstErr = "$($e.Name): $($_.Exception.Message)" } }
            }
        } catch { $failed++; if (-not $firstErr) { $firstErr = $_.Exception.Message } }
    }
    foreach ($d in @($dirs | Sort-Object { $_.Length } -Descending)) {
        try {
            if (([IO.File]::GetAttributes($d)) -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($d, [IO.FileAttributes]::Directory) }
            [IO.Directory]::Delete($d, $false)
        } catch { if ($d -eq $Path -and -not $firstErr) { $firstErr = $_.Exception.Message } }   # thư mục cha của mục bị từ chối: đã tính ở trên
    }
    $removed = -not (Test-Path -LiteralPath $Path)
    if (-not $removed -and $failed -eq 0) { $failed = 1 }
    return [pscustomobject]@{ bytes = $bytes; count = $count; failed = $failed; firstError = $firstErr; removed = $removed }
}

function Find-RgWorkspaceArtifacts([string[]]$Roots, [int]$MaxDepth) {
    $out = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $stack.Push(@($root, 0))
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            $dir = [string]$cur[0]; $depth = [int]$cur[1]
            try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
            foreach ($s in $subs) {
                $leaf = [IO.Path]::GetFileName($s)
                try { $attr = [IO.File]::GetAttributes($s) } catch { continue }
                if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($leaf -ieq '.git') { continue }
                if ($leaf -ieq 'node_modules') {
                    if (Test-Path -LiteralPath (Join-Path $dir 'package.json')) { $out += [pscustomobject]@{ Path = $s; Kind = 'node_modules' } }
                    continue
                }
                if ($leaf -ieq 'bin' -or $leaf -ieq 'obj') {
                    $hasProj = @([IO.Directory]::EnumerateFiles($dir, '*.*proj')).Count -gt 0
                    if ($hasProj) { $out += [pscustomobject]@{ Path = $s; Kind = 'dotnet-artifact' } }
                    continue
                }
                if (($depth + 1) -lt $MaxDepth) { $stack.Push(@($s, ($depth + 1))) }
            }
        }
    }
    return $out
}

function Get-RgTempRoot($Cfg) {
    if ($Cfg.cleanup.tempRoot) { return (Expand-RgPath $Cfg.cleanup.tempRoot).TrimEnd('\') }
    return ([IO.Path]::GetTempPath()).TrimEnd('\')
}

# Mục có do tài khoản hiện tại (hoặc nhóm Administrators khi đang elevated) sở hữu không?
# Mục do SYSTEM/tài khoản khác tạo trong Temp (ACL chỉ cho user quyền đọc) thì tool không xoá được -> không đề xuất xoá.
function Test-RgOwnedByCurrentUser([string]$Path) {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier])
        if ($owner -eq $id.User) { return $true }
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        return ($isAdmin -and $owner.IsWellKnown([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid))
    } catch { return $false }
}

# Kiểm tra DÀNH RIÊNG cho tiến trình elevated (xoá mục temp do SYSTEM/Administrators sở hữu). Không dựa vào dữ liệu
# từ server/UI/state: chỉ nhận đúng thư mục con trực tiếp của %TEMP% mang tên GUID (hoặc GUID.scratch), đủ tuổi,
# không junction, không segment bảo vệ, chủ sở hữu là user hiện tại / SYSTEM / Administrators. Trả lý do chặn hoặc $null.
function Get-RgElevatedDeleteBlocker([string]$Path, $Cfg, [string]$TempRoot) {
    if (-not [IO.Path]::IsPathRooted($Path)) { return 'path is not absolute' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -ne $Path.TrimEnd('\')) { return 'path is not normalized' }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return 'directory no longer exists' }
    if (Test-RgReparse $full) { return 'path is a junction/symlink or unreadable' }
    if ((Split-Path $full -Parent).TrimEnd('\') -ine $TempRoot.TrimEnd('\')) { return 'not a direct child of the temp root' }
    $leaf = Split-Path $full -Leaf
    if ($leaf -notmatch '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(\.scratch)?$') { return 'name is not a GUID or GUID.scratch' }
    foreach ($n in @($Cfg.protected.segments)) { if ($full.Split('\') -contains $n) { return "protected path segment '$n'" } }
    $sid = $null
    try { $sid = (Get-Acl -LiteralPath $full -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]) } catch { return 'owner is unreadable' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if (-not ($sid -eq $me -or $sid.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
            $sid.IsWellKnown([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid))) { return 'owner is not the user, SYSTEM or Administrators' }
    $min = [math]::Max(14, [int]$Cfg.cleanup.minAgeDays.'temp-entry')   # sàn cố định: không hạ thấp được bằng config
    $st = Get-RgDirStats $full
    $newest = $st.newestUtc; $dt = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
    if ($dt -gt $newest) { $newest = $dt }
    if (((Get-Date).ToUniversalTime() - $newest).TotalDays -lt $min) { return "modified within the last $min days" }
    return $null
}

function New-RgItem {
    param([string]$Kind, [string]$Action, [int]$Level, [string]$Path = '', [int]$ProcId = 0, [string]$Start = '',
        [string]$Name = '', [long]$SizeBytes = 0, [string]$NewestUtc = '', [string]$Reason = '', [string]$Risk = '', [int]$AgeDays = 0,
        [bool]$NeedsAdmin = $false, [bool]$Archive = $false, [bool]$Young = $false)
    return [ordered]@{
        id = 0; kind = $Kind; action = $Action; level = $Level; path = $Path; pid = $ProcId; start = $Start
        name = $Name; sizeBytes = $SizeBytes; ageDays = $AgeDays; newestWriteUtc = $NewestUtc; reason = $Reason; risk = $Risk
        needsAdmin = $NeedsAdmin; archive = $Archive; young = $Young
    }
}

# Mục "young" = dưới ngưỡng tuổi của policy nhưng vẫn được đưa vào danh sách để agent/người dùng cân nhắc.
# Tuổi chỉ là một tín hiệu; mục young KHÔNG BAO GIỜ được tự dọn, chỉ xoá khi người duyệt.
# cleanup.youngMinMB: dung lượng tối thiểu để đưa mục young vào danh sách (mặc định 50; số âm = tắt hẳn).
function Get-RgYoungMinBytes($Cfg) {
    $mb = 50
    if ($Cfg.cleanup.PSObject.Properties['youngMinMB'] -and $null -ne $Cfg.cleanup.youngMinMB) { $mb = [double]$Cfg.cleanup.youngMinMB }
    if ($mb -lt 0) { return -1L }
    return [long]($mb * 1MB)
}

# ---------- Biên lai mục dọn (why / impact / regen / regenHint / riskLevel) ----------
# Chữ cho người dùng, tiếng Việt. KHÔNG thay thế `reason`/`risk` (chuỗi tiếng Anh mà test đang so khớp).

function Format-RgSizeVi([long]$Bytes) {
    $ci = [Globalization.CultureInfo]::GetCultureInfo('vi-VN')
    if ($Bytes -ge 1GB) { return ('{0} GB' -f ([math]::Round($Bytes / 1GB, 1)).ToString('0.0', $ci)) }
    if ($Bytes -ge 1MB) { return ('{0} MB' -f [math]::Round($Bytes / 1MB).ToString('0', $ci)) }
    return ('{0} KB' -f [math]::Round($Bytes / 1KB).ToString('0', $ci))
}

# Số ngày kể từ lần ghi cuối: ưu tiên ageDays (mục young), nếu không thì tính từ newestWriteUtc, không có thì $null.
function Get-RgItemAgeDays($Item) {
    if ([int]$Item.ageDays -gt 0) { return [int]$Item.ageDays }
    $s = [string]$Item.newestWriteUtc
    if ($s) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt)) {
            return [int][math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - $dt).TotalDays))
        }
    }
    return $null
}

function Step-RgRiskLevel([string]$Level) {
    switch ($Level) { 'low' { return 'medium' } 'medium' { return 'high' } default { return 'high' } }
}

# Khả năng lấy lại của từng loại mục (A3): quyết định cách trợ lý được phép đề xuất và cách journal ghi nhận.
#   regenerable  = tự sinh lại được (build lại / cài lại / tải lại): xoá thẳng là chấp nhận được
#   zip-optional = không sinh lại được nhưng có thể nén zip có xác minh trước khi xoá (mã nằm trên remote, hoặc file cá nhân)
#   none         = không phải thao tác xoá (tiến trình, chỉ báo cáo)
# Loại nào KHÔNG phải 'regenerable' thì không bao giờ vào nhóm tự dọn (categories của policy chỉ gồm các loại regenerable + process).
function Get-RgKindRecovery([string]$Kind) {
    switch ($Kind) {
        { @('temp-entry', 'dotnet-artifact', 'node_modules', 'cache-aged') -contains $_ } { return 'regenerable' }
        { @('stale-repo', 'large-item', 'cluster-file') -contains $_ } { return 'zip-optional' }
        default { return 'none' }
    }
}

# Plan kẹt ở 'applying' (process chết giữa lượt thi hành). Chạy lại apply sẽ revalidate từng mục; mục đã xoá bị bỏ qua.
function Get-RgResumablePlans {
    $out = @()
    $dir = Join-Path (Initialize-RgHome) 'plans'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $p = ConvertFrom-Json (Read-RgFileShared $f.FullName)
            if ([string]$p.status -eq 'applying' -and [string]$p.approval.status -eq 'approved') {
                $out += [pscustomobject]@{ planId = [string]$p.planId; createdUtc = [string]$p.createdUtc; approvedItems = @($p.approval.approvedItemIds).Count }
            }
        } catch { }
    }
    return $out
}

# Dựng biên lai cho MỘT mục (hashtable từ New-RgItem hoặc object đọc từ scan-candidates.json).
# Trả về [ordered]@{ why; impact; regen; regenHint; riskLevel; recovery }.
function Get-RgItemReceipt($Item, $Cfg) {
    $kind = [string]$Item.kind; $action = [string]$Item.action
    $young = [bool]$Item.young
    $age = Get-RgItemAgeDays $Item
    $ageTxt = if ($null -ne $age) { "$age ngày" } else { 'một thời gian' }
    $size = Format-RgSizeVi ([long]$Item.sizeBytes)
    $leaf = ''
    if ($Item.path) { $leaf = [IO.Path]::GetFileName(([string]$Item.path).TrimEnd('\')) }
    $min = $null
    try { if ($Cfg -and $Cfg.cleanup.minAgeDays.PSObject.Properties[$kind]) { $min = [int]$Cfg.cleanup.minAgeDays.$kind } } catch { }
    $minTxt = if ($null -ne $min) { "$min ngày" } else { 'ngưỡng tuổi' }
    $youngWhy = "Mới sửa cách đây $ageTxt (dưới ngưỡng $minTxt): chưa chắc đã bỏ. Mục này không bao giờ tự dọn, chỉ xoá khi bạn duyệt."

    $why = ''; $impact = ''; $regen = 'none'; $regenHint = ''; $risk = 'medium'
    switch ($kind) {
        'temp-entry' {
            $risk = 'low'; $regen = 'auto'
            $impact = 'Không ảnh hưởng; chương trình tự tạo lại khi cần.'
            $regenHint = 'Không cần làm gì: chương trình sinh lại file tạm khi chạy.'
            $why = if ($young) { $youngWhy } else { "File tạm không được dùng $ageTxt ($size)." }
        }
        'dotnet-artifact' {
            $risk = 'low'; $regen = 'rebuild'
            $impact = 'Lần build kế tiếp của dự án này chậm hơn vì build lại từ đầu.'
            $regenHint = 'Chạy lại lệnh build (dotnet build) trong dự án; thư mục bin/obj được sinh lại.'
            $why = if ($young) { $youngWhy } else { "Kết quả build (bin/obj) không đụng tới $ageTxt ($size); build kế tiếp sẽ sinh lại." }
        }
        'node_modules' {
            $risk = 'medium'; $regen = 'redownload'
            $impact = 'Phải chạy lại lệnh cài gói trước khi chạy dự án; cần mạng.'
            $regenHint = 'Chạy npm install / pnpm install / yarn trong thư mục dự án (cần kết nối mạng).'
            $why = if ($young) { $youngWhy } else { "node_modules không đụng tới $ageTxt ($size); dự án có thể cài lại từ package.json." }
        }
        'cache-aged' {
            $risk = 'low'; $regen = 'redownload'
            $impact = 'Lần restore sau tải lại gói còn thiếu; cần mạng.'
            $regenHint = 'Tự tải lại gói khi build/restore lần sau (cần kết nối mạng).'
            $cd = $null; try { $cd = [int]$Cfg.cleanup.cacheMinInactiveDays } catch { }
            $cdTxt = if ($cd) { "$cd ngày" } else { 'nhiều ngày' }
            $why = if ($young) { "Toàn bộ bộ nhớ đệm ($size), kể cả gói mới dùng trong $cdTxt qua. Chồng lên mục 'không dùng $cdTxt'. Chưa chắc đã bỏ; không bao giờ tự dọn." }
            else { "Gói trong bộ nhớ đệm không được đọc/ghi từ $cdTxt trở lên ($size)." }
        }
        'stale-repo' {
            $risk = 'medium'; $regen = 'restore-zip'
            $impact = 'Mã đã có trên remote, clone lại khi cần; có bản zip nếu chọn nén. File bị git bỏ qua (như .env) không có trên remote.'
            $regenHint = 'Clone lại từ remote, hoặc giải nén bản zip nếu bạn chọn nén trước khi xoá.'
            $why = "Repo không có thay đổi mã nguồn $ageTxt ($size); mọi commit đã có trên remote."
        }
        'large-item' {
            $risk = 'high'; $regen = 'restore-zip'
            $impact = 'Không tự tạo lại được; có bản zip nếu chọn nén.'
            $regenHint = 'Chỉ khôi phục được từ bản zip nếu bạn chọn nén trước khi xoá.'
            $why = "Mục lớn ($size) không đụng tới $ageTxt" + $(if ($leaf) { ": $leaf." } else { '.' })
        }
        'cluster-file' {
            $risk = 'medium'; $regen = 'restore-zip'
            $impact = 'File cá nhân: chỉ nên nén (có bản zip để khôi phục). Xoá không nén thì không lấy lại được.'
            $regenHint = 'Khôi phục từ bản zip ở mục Bản đã nén nếu bạn chọn nén trước khi xoá.'
            $why = "Tệp $size không đụng tới $ageTxt" + $(if ($leaf) { ": $leaf." } else { '.' })
        }
        'process' {
            $risk = 'medium'; $regen = 'none'
            $impact = 'Tiến trình bị kết thúc; việc chưa lưu trong tiến trình đó sẽ mất.'
            $regenHint = 'Khởi động lại ứng dụng nếu cần.'
            $nm = [string]$Item.name
            $why = if ($action -eq 'kill') { "Tiến trình $nm do trợ lý đăng ký, nhưng tiến trình chủ đã kết thúc ($size RAM)." }
            else { "Tiến trình $nm đang chiếm $size RAM và không còn tiến trình cha; không do trợ lý nào đăng ký." }
        }
        'vhdx' {
            $risk = 'high'; $regen = 'none'
            $impact = 'Chỉ báo cáo; Resource Guard không xoá loại này.'
            $regenHint = 'Thu gọn thủ công (docker builder prune, wsl --manage <distro> --set-sparse true).'
            $why = "Ổ ảo WSL/Docker chiếm $size" + $(if ($leaf) { ": $leaf." } else { '.' })
        }
        'app' {
            $risk = 'high'; $regen = 'none'
            $impact = 'Chỉ báo cáo; Resource Guard không xoá loại này.'
            $regenHint = 'Gỡ cài đặt ở Cài đặt > Ứng dụng nếu không còn dùng.'
            $why = "Ứng dụng không ghi file $ageTxt ($size)" + $(if ($leaf) { ": $leaf." } else { '.' })
        }
        default {
            $risk = 'medium'; $regen = 'none'
            $impact = 'Chưa rõ ảnh hưởng của loại mục này.'
            $regenHint = 'Không có hướng dẫn lấy lại cho loại mục này.'
            $why = "Mục $kind chiếm $size."
        }
    }
    # Mục chỉ báo cáo (không xoá được): nói rõ, trừ các loại vốn đã là chỉ báo cáo.
    if ($action -eq 'report' -and $kind -notin @('vhdx', 'app', 'process')) {
        $impact = "Chỉ báo cáo: Resource Guard không tự xoá mục này. " + $impact
        if ([bool]$Item.needsAdmin) { $why += ' Thuộc tài khoản khác nên cần quyền admin.' }
    }
    if ($action -eq 'report' -and $kind -eq 'process') { $impact = 'Chỉ báo cáo; Resource Guard không kết thúc tiến trình này.' }
    # Mục young: rủi ro tăng một bậc (người dùng/agent phải tự cân nhắc).
    if ($young) { $risk = Step-RgRiskLevel $risk }
    return [ordered]@{ why = $why; impact = $impact; regen = $regen; regenHint = $regenHint; riskLevel = $risk; recovery = (Get-RgKindRecovery $kind) }
}

function Get-RgCandidates {
    $cfg = Get-RgConfig
    $now = (Get-Date).ToUniversalTime()
    $items = @()
    $youngMin = Get-RgYoungMinBytes $cfg   # mục dưới ngưỡng tuổi: vẫn đưa vào (gắn young) nếu đủ lớn, để agent/người dùng quyết

    # 1) Artifact trong workspace: bin/obj, node_modules (mục chưa đủ tuổi gắn young)
    $roots = @(Get-RgWorkspaceRoots $cfg.cleanup)
    foreach ($a in (Find-RgWorkspaceArtifacts $roots ([int]$cfg.cleanup.maxDepth))) {
        $st = Get-RgDirStats $a.Path
        $dirTime = (Get-Item -LiteralPath $a.Path -Force).LastWriteTimeUtc
        $newest = $st.newestUtc; if ($dirTime -gt $newest) { $newest = $dirTime }
        $ageDays = [math]::Floor(($now - $newest).TotalDays)
        $min = [int]$cfg.cleanup.minAgeDays.($a.Kind)
        $young = $ageDays -lt $min
        if ($young -and ($youngMin -lt 0 -or $st.bytes -lt $youngMin)) { continue }
        $ageArg = if ($young) { [int]$ageDays } else { 0 }
        $yNote = if ($young) { "; modified only $ageDays days ago (below the $min-day floor): agent/user must judge, never auto-cleaned" } else { '' }
        if ($a.Kind -eq 'dotnet-artifact') {
            $items += New-RgItem -Kind $a.Kind -Action 'delete' -Level 1 -Path $a.Path -SizeBytes $st.bytes -NewestUtc (ConvertTo-RgStamp $newest) -AgeDays $ageArg -Young $young `
                -Reason $(if ($young) { "build output (regenerated by next build)$yNote" } else { "build output untouched for $ageDays days (regenerated by next build)" }) `
                -Risk $(if ($young) { 'medium: recently built, may be in use by a running build/debug session' } else { 'low' })
        } else {
            $items += New-RgItem -Kind $a.Kind -Action 'delete' -Level 2 -Path $a.Path -SizeBytes $st.bytes -NewestUtc (ConvertTo-RgStamp $newest) -AgeDays $ageArg -Young $young `
                -Reason $(if ($young) { "node_modules (restore with package manager)$yNote" } else { "node_modules untouched for $ageDays days (restore with package manager)" }) `
                -Risk $(if ($young) { 'high: project is likely in active use; needs reinstall + network' } else { 'medium: needs reinstall + network' })
        }
    }

    # 2) Temp entries cũ (top N theo dung lượng)
    $tempRoot = Get-RgTempRoot $cfg
    $temp = @(); $tempYoung = @()
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($e in (Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $skip = $false
            foreach ($pat in @($cfg.cleanup.tempExclude)) { if ($e.Name -like $pat) { $skip = $true } }
            if ($skip) { continue }
            if ($e.PSIsContainer) {
                $st = Get-RgDirStats $e.FullName
                $size = $st.bytes; $newest = $st.newestUtc
                if ($e.LastWriteTimeUtc -gt $newest) { $newest = $e.LastWriteTimeUtc }
            } else { $size = $e.Length; $newest = $e.LastWriteTimeUtc }
            $ageDays = [math]::Floor(($now - $newest).TotalDays)
            if ($ageDays -lt [int]$cfg.cleanup.minAgeDays.'temp-entry') {
                # chưa đủ tuổi: chỉ đưa vào khi đủ lớn và xoá được bằng quyền hiện tại (mục của tài khoản khác bỏ qua)
                if ($youngMin -ge 0 -and $size -ge $youngMin -and (Test-RgOwnedByCurrentUser $e.FullName)) {
                    $tempYoung += New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 2 -Path $e.FullName -SizeBytes $size -NewestUtc (ConvertTo-RgStamp $newest) -AgeDays ([int]$ageDays) -Young $true `
                        -Reason "temp entry modified only $ageDays days ago (below the $([int]$cfg.cleanup.minAgeDays.'temp-entry')-day floor): agent/user must judge, never auto-cleaned" -Risk 'medium: may belong to a running process'
                }
                continue
            }
            if (-not (Test-RgOwnedByCurrentUser $e.FullName)) {
                # không nằm trong tempTop: mục không xoá được không được chiếm chỗ của mục xoá được
                # chỉ gắn needsAdmin khi tiến trình elevated cũng sẽ chấp nhận mục này (cùng bộ kiểm tra độc lập)
                $realTemp = ([IO.Path]::GetTempPath()).TrimEnd('\')
                $adm = $null -eq (Get-RgElevatedDeleteBlocker $e.FullName $cfg $realTemp)
                $why = if ($adm) { 'needs admin rights: you can approve it with a UAC prompt in the UI' } else { 'remove it from an elevated shell' }
                $items += New-RgItem -Kind 'temp-entry' -Action 'report' -Level 3 -Path $e.FullName -SizeBytes $size -NewestUtc (ConvertTo-RgStamp $newest) `
                    -Reason "temp entry untouched for $ageDays days, but owned by another account (e.g. SYSTEM); $why" -Risk 'protected: needs admin' -NeedsAdmin $adm
                continue
            }
            $temp += New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path $e.FullName -SizeBytes $size -NewestUtc (ConvertTo-RgStamp $newest) `
                -Reason "temp entry untouched for $ageDays days" -Risk 'low: may fail if still locked'
        }
    }
    $items += @($temp | Sort-Object { $_.sizeBytes } -Descending | Select-Object -First ([int]$cfg.cleanup.tempTop))
    $items += @($tempYoung | Sort-Object { $_.sizeBytes } -Descending | Select-Object -First 15)

    # 3) Cache dùng chung: chỉ file không hoạt động >= N ngày (cần duyệt)
    $cacheDays = [int]$cfg.cleanup.cacheMinInactiveDays
    foreach ($prop in $cfg.cleanup.cacheDirs.PSObject.Properties) {
        $p = (Expand-RgPath ([string]$prop.Value)).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if (Test-RgReparse $p) { continue }
        $ag = Invoke-RgAgedFiles -Path $p -Days $cacheDays
        if ($ag.bytes -ge ([long]$cfg.cleanup.minCacheMB * 1MB)) {
            $items += New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $p -SizeBytes $ag.bytes -AgeDays $cacheDays `
                -Reason "$($prop.Name): $($ag.count) files not written or accessed for >= $cacheDays days; re-downloaded on demand" -Risk 'medium: slow next restore, needs network'
        }
        # Cả phần file mới dùng gần đây: tuổi thấp chưa chắc cần giữ (cache tải lại được). Mục young, ageDays=0 => xoá toàn bộ nội dung cache.
        if ($youngMin -ge 0) {
            $tot = Get-RgDirStats $p
            if (($tot.bytes - $ag.bytes) -ge $youngMin) {
                $items += New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $p -SizeBytes $tot.bytes -AgeDays 0 -NewestUtc (ConvertTo-RgStamp $tot.newestUtc) -Young $true `
                    -Reason "$($prop.Name): WHOLE cache incl. files used within $cacheDays days ($([math]::Round(($tot.bytes - $ag.bytes) / 1MB)) MB of it recent); re-downloaded on demand. Overlaps the aged-only item; agent/user must judge, never auto-cleaned" `
                    -Risk 'medium-high: may be in use by a running build/restore; slow next restore, needs network'
            }
        }
    }

    # 4) VHDX của WSL/Docker: chỉ báo cáo, không bao giờ xoá
    foreach ($g in @($cfg.cleanup.vhdxGlobs)) {
        foreach ($f in @(Get-ChildItem -Path (Expand-RgPath $g) -File -ErrorAction SilentlyContinue)) {
            $items += New-RgItem -Kind 'vhdx' -Action 'report' -Level 3 -Path $f.FullName -SizeBytes $f.Length -NewestUtc (ConvertTo-RgStamp $f.LastWriteTimeUtc) `
                -Reason 'WSL/Docker virtual disk; compact manually (docker builder prune, wsl --manage <distro> --set-sparse true)' -Risk 'protected: report only'
        }
    }

    # 4b) Repo lâu không dùng (chỉ khi mọi thứ còn có bản ở remote), mục dung lượng lớn lâu không đụng, ứng dụng (chỉ báo cáo)
    $items += @(Get-RgStaleRepoCandidates $cfg)
    $items += @(Get-RgLargeItemCandidates $cfg)
    $items += @(Get-RgAppCandidates $cfg)

    # 5) Process: orphan của agent (kill được) + ứng viên không có trong ledger (chỉ báo cáo)
    $table = Get-RgProcessTable
    $ledgerOrphans = @(Get-RgLedgerOrphans)
    $ledgerKeys = @{}
    foreach ($e in $ledgerOrphans) {
        $ledgerKeys["$($e.pid)|$($e.start)"] = $true
        $ram = 0; $row = $table | Where-Object { $_.Pid -eq [int]$e.pid } | Select-Object -First 1
        if ($row) { $ram = $row.RamMB }
        $items += New-RgItem -Kind 'process' -Action 'kill' -Level 1 -ProcId ([int]$e.pid) -Start ([string]$e.start) -Name ([string]$e.name) `
            -SizeBytes ([long]$ram * 1MB) -Reason "registered by $($e.agent) ($($e.label)); owner pid $($e.ownerPid) is gone" -Risk 'low: matched by pid + start time'
    }
    $cand = @(Get-RgOrphanCandidates $table | Where-Object { $_.RamMB -ge 100 -and -not $ledgerKeys.ContainsKey("$($_.Pid)|$($_.Start)") } |
            Sort-Object RamMB -Descending | Select-Object -First 10)
    foreach ($p in $cand) {
        $items += New-RgItem -Kind 'process' -Action 'report' -Level 2 -ProcId $p.Pid -Start $p.Start -Name $p.Name -SizeBytes ([long]$p.RamMB * 1MB) `
            -Reason "$($p.Group) process whose parent is gone; not registered by any agent (may be your own dev server)" -Risk 'unknown: report only'
    }
    # Biên lai cho người dùng (why/impact/regen/regenHint/riskLevel): dựng ở MỘT chỗ, không sửa từng lời gọi New-RgItem.
    foreach ($i in $items) {
        $rc = Get-RgItemReceipt $i $cfg
        foreach ($k in $rc.Keys) { $i[$k] = $rc[$k] }
    }
    # C2 (U7): nhóm "Tệp tạm & cache" cho biết mục nào đang được process khác dùng (chỉ thông tin; việc bỏ qua xảy ra lúc dọn, kiểm lại ngay trước khi xoá).
    if (Test-RgHeldProbeEnabled $cfg) {
        foreach ($i in $items) {
            if ($i.action -ne 'delete' -or @('temp-entry', 'cache-aged') -notcontains [string]$i.kind) { continue }
            $minAge = 0; if ([string]$i.kind -eq 'cache-aged' -and -not [bool]$i.young) { $minAge = [int]$i.ageDays }
            $hi = Get-RgHeldInfo -Path ([string]$i.path) -MinAgeDays $minAge
            $i['heldBy'] = @($hi.holders | Select-Object -First 3 | ForEach-Object { "$($_.name) (pid $($_.pid))" })
        }
    }
    return $items
}

# ---------- Plan ----------

function Get-RgItemsHash($Items) {
    $lines = @(foreach ($i in @($Items)) {
            $l = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $i.id, $i.kind, $i.action, $i.path, $i.pid, $i.start, $i.name, $i.sizeBytes, $i.ageDays, [bool]$i.archive
            if ([bool]$i.young) { $l += '|young' }   # chỉ thêm khi true: plan cũ (không có cờ) giữ nguyên hash
            $l
        })
    return (Get-RgSha256 ($lines -join "`n"))
}

function Get-RgPlanPath([string]$PlanId) {
    if ($PlanId -notmatch '^[0-9a-f]{12}$') { throw "Invalid plan id '$PlanId'." }
    return (Join-Path (Initialize-RgHome) "plans\$PlanId.json")
}

function Read-RgPlan([string]$PlanId) {
    $p = Get-RgPlanPath $PlanId
    if (-not (Test-Path -LiteralPath $p)) { throw "Plan $PlanId not found." }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-RgPlan($Plan) {
    Write-RgFileAtomic (Get-RgPlanPath $Plan.planId) (ConvertTo-Json -InputObject $Plan -Depth 8)
}

function New-RgPlan {
    param($Items)
    [void](Initialize-RgHome)
    $sorted = @($Items | Sort-Object @{ Expression = { $_.level } }, @{ Expression = { $_.sizeBytes }; Descending = $true })
    $n = 1
    foreach ($i in $sorted) { $i['id'] = $n; $n++ }
    $reclaim = 0L
    foreach ($i in $sorted) { if ($i.action -eq 'delete') { $reclaim += [long]$i.sizeBytes } }   # Measure-Object không đọc key hashtable trên PS 5.1
    $created = Get-RgNowStamp
    $itemsHash = Get-RgItemsHash $sorted
    $plan = [ordered]@{
        planId     = (Get-RgSha256 ($itemsHash + $created)).Substring(0, 12)
        createdUtc = $created
        machine    = $env:COMPUTERNAME
        itemsHash  = $itemsHash
        status     = 'pending'
        totalReclaimableBytes = $reclaim
        items      = $sorted
        approval   = [ordered]@{ status = 'pending'; approvedItemIds = @(); itemsHash = $null; approvedBy = $null; approvedUtc = $null }
        results    = @()
    }
    Save-RgPlan $plan
    Write-RgLog 'plan-created' @{ planId = $plan.planId; items = $sorted.Count; reclaimBytes = $plan.totalReclaimableBytes }
    return (Read-RgPlan $plan.planId)
}

# Ghi approval vào plan (không tương tác). Người dùng đi qua Approve-RgPlan; hàm này tách ra để test.
function Set-RgPlanApproval {
    param([string]$PlanId, [int[]]$ItemIds, [string]$By = '')
    $plan = Read-RgPlan $PlanId
    if ((Get-RgItemsHash $plan.items) -ne $plan.itemsHash) { throw 'Plan items do not match plan hash; refusing to approve.' }
    foreach ($id in $ItemIds) {
        $it = @($plan.items | Where-Object { $_.id -eq $id })
        if ($it.Count -ne 1) { throw "Item $id not in plan." }
        if ($it[0].action -eq 'report') { throw "Item $id is report-only and cannot be approved." }
    }
    $plan.approval.status = 'approved'
    $plan.approval.approvedItemIds = @($ItemIds)
    $plan.approval.itemsHash = $plan.itemsHash
    $plan.approval.approvedBy = $By
    $plan.approval.approvedUtc = Get-RgNowStamp
    Save-RgPlan $plan
    Write-RgLog 'plan-approved' @{ planId = $PlanId; items = @($ItemIds); by = $By }
    return (Read-RgPlan $PlanId)
}

# Duyệt do con người: yêu cầu console tương tác (stdin không bị redirect) và gõ lại plan id.
# Agent chạy qua tool/hook có stdin redirect nên không đi qua được. Đây là rào chắn thực dụng, không phải ranh giới bảo mật.
function Approve-RgPlan {
    param([string]$PlanId, [int[]]$ItemIds, [switch]$All)
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        throw 'Approval requires a human at an interactive console (stdin is redirected).'
    }
    $plan = Read-RgPlan $PlanId
    $actionable = @($plan.items | Where-Object { $_.action -ne 'report' })
    if ($All) { $ItemIds = @($actionable | ForEach-Object { $_.id }) }
    if (-not $ItemIds -or $ItemIds.Count -eq 0) { throw 'Specify -ItemIds or -All.' }
    $sel = @($plan.items | Where-Object { $ItemIds -contains $_.id })
    $sel | Select-Object id, kind, action, @{ n = 'MB'; e = { [math]::Round($_.sizeBytes / 1MB, 1) } }, path, pid, name, risk | Format-Table -AutoSize | Out-String | Write-Host
    $ans = Read-Host "Type the plan id ($PlanId) to approve these $($sel.Count) item(s)"
    if ($ans -ne $PlanId) { throw 'Confirmation mismatch; nothing approved.' }
    return (Set-RgPlanApproval -PlanId $PlanId -ItemIds $ItemIds -By "$env:USERDOMAIN\$env:USERNAME")
}

# ---------- Tiến trình đang giữ file (C2, U7) ----------
# Windows Restart Manager (rstrtmgr.dll), chỉ ĐỌC: hỏi "process nào đang mở các file này". Spike C1: chạy không cần admin, ~10-15 ms/lần,
# nhưng KHÔNG nhận thư mục (lỗi 5) nên phải hỏi từng file. Không gọi RmShutdown/RmRestart: chỉ biết, không đóng gì.
# Mục bị giữ => bỏ qua lúc dọn, kèm tên process; probe không chạy được thì KHÔNG chặn (xoá file bị khoá vẫn tự thất bại và được báo).

$script:RgHolderReady = $null

function Initialize-RgHolderProbe {
    if ($null -ne $script:RgHolderReady) { return [bool]$script:RgHolderReady }
    try {
        if (-not ('RgHolderProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class RgHolderProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, out uint lpdwRebootReasons);

    public class Holder { public int Pid; public string Name; public string Type; public long StartFileTime; }
    public class Result { public int Code; public string Step; public List<Holder> Holders = new List<Holder>(); }

    static string TypeName(int t)
    {
        switch (t) { case 1: return "mainwindow"; case 2: return "otherwindow"; case 3: return "service"; case 4: return "explorer"; case 5: return "console"; case 1000: return "critical"; default: return "unknown"; }
    }

    public static Result Probe(string[] files)
    {
        Result r = new Result();
        uint h;
        StringBuilder key = new StringBuilder(33);
        int rc = RmStartSession(out h, 0, key);
        if (rc != 0) { r.Code = rc; r.Step = "RmStartSession"; return r; }
        try
        {
            rc = RmRegisterResources(h, (uint)files.Length, files, 0, null, 0, null);
            if (rc != 0) { r.Code = rc; r.Step = "RmRegisterResources"; return r; }
            uint needed = 0, count = 0, reasons = 0;
            rc = RmGetList(h, out needed, ref count, null, out reasons);
            if (rc == 0) { r.Step = "none"; return r; }
            if (rc != 234) { r.Code = rc; r.Step = "RmGetList(size)"; return r; }
            RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed + 4];
            count = (uint)info.Length;
            rc = RmGetList(h, out needed, ref count, info, out reasons);
            if (rc != 0) { r.Code = rc; r.Step = "RmGetList(data)"; return r; }
            for (int i = 0; i < count; i++)
            {
                Holder x = new Holder();
                x.Pid = info[i].Process.dwProcessId; x.Name = info[i].strAppName; x.Type = TypeName(info[i].ApplicationType);
                x.StartFileTime = ((long)info[i].Process.ProcessStartTime.dwHighDateTime << 32) | (uint)info[i].Process.ProcessStartTime.dwLowDateTime;
                r.Holders.Add(x);
            }
            r.Step = "ok";
            return r;
        }
        finally { RmEndSession(h); }
    }
}
'@
        }
        $script:RgHolderReady = $true
    } catch { $script:RgHolderReady = $false; Write-RgLog 'held-probe-init-error' @{ error = [string]$_.Exception.Message } }
    return [bool]$script:RgHolderReady
}

# Danh sách process đang giữ các file này (bỏ chính process hiện tại). { ok; failedChunks; holders[{pid,name,type,startUtc}] }
function Get-RgFileHolders([string[]]$Files) {
    $files = @($Files | Where-Object { $_ })
    $res = [ordered]@{ ok = $true; failedChunks = 0; holders = @() }
    if ($files.Count -eq 0) { return [pscustomobject]$res }
    if (-not (Initialize-RgHolderProbe)) { $res.ok = $false; return [pscustomobject]$res }
    $seen = @{}; $list = @()
    for ($i = 0; $i -lt $files.Count; $i += 200) {
        $chunk = [string[]]@($files[$i..([math]::Min($i + 199, $files.Count - 1))])
        $r = $null
        try { $r = [RgHolderProbe]::Probe($chunk) } catch { $res.failedChunks++; continue }
        if ($r.Code -ne 0) { $res.failedChunks++; continue }
        foreach ($h in $r.Holders) {
            if ($h.Pid -eq $PID) { continue }
            $k = "$($h.Pid)|$($h.StartFileTime)"
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $list += [pscustomobject]@{ pid = [int]$h.Pid; name = [string]$h.Name; type = [string]$h.Type; startUtc = ([datetime]::FromFileTimeUtc([long]$h.StartFileTime)).ToString('yyyyMMdd\THHmmss\Z') }
        }
    }
    if ($res.failedChunks -gt 0) { $res.ok = $false }
    $res.holders = @($list)
    return [pscustomobject]$res
}

# Ai đang giữ file trong $Path (một file, hoặc thư mục: duyệt có giới hạn, không đi xuyên junction/symlink).
# Thư mục lớn: chỉ hỏi $MaxFiles file ghi gần đây nhất + 30 file lớn nhất trong $MaxWalk file đầu tiên (file đang mở thường là file mới ghi hoặc lớn).
# MinAgeDays > 0: chỉ xét file không hoạt động quá ngần ấy ngày (đúng tập file mà bước xoá cache-aged sẽ đụng tới).
# { ok; checked; walked; truncated; holders[] }
function Get-RgHeldInfo {
    param([string]$Path, [int]$MinAgeDays = 0, [int]$MaxFiles = 150, [int]$MaxWalk = 5000)
    $out = [ordered]@{ ok = $true; checked = 0; walked = 0; truncated = $false; holders = @() }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$out }
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $files = @($Path); $out.walked = 1 }
    else {
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-[math]::Max(0, $MinAgeDays))
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Path)
        while ($stack.Count -gt 0 -and -not $out.truncated) {
            $d = $stack.Pop()
            try {
                foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName); continue }
                    if ($MinAgeDays -gt 0) {
                        $act = $e.LastWriteTimeUtc; if ($e.LastAccessTimeUtc -gt $act) { $act = $e.LastAccessTimeUtc }
                        if ($act -ge $cutoff) { continue }
                    }
                    [void]$rows.Add([pscustomobject]@{ p = $e.FullName; t = $e.LastWriteTimeUtc.Ticks; n = [long]$e.Length })
                    if ($rows.Count -ge $MaxWalk) { $out.truncated = $true; break }
                }
            } catch { }
        }
        $out.walked = $rows.Count
        $pick = @{}
        foreach ($r in @($rows | Sort-Object t -Descending | Select-Object -First $MaxFiles)) { $pick[$r.p] = $true }
        foreach ($r in @($rows | Sort-Object n -Descending | Select-Object -First 30)) { $pick[$r.p] = $true }
        $files = @($pick.Keys)
        if ($rows.Count -gt $files.Count) { $out.truncated = $true }
    }
    $out.checked = $files.Count
    if ($files.Count -eq 0) { return [pscustomobject]$out }
    $h = Get-RgFileHolders $files
    $out.ok = [bool]$h.ok
    $out.holders = @($h.holders)
    return [pscustomobject]$out
}

function Test-RgHeldProbeEnabled($Cfg) {
    if ($Cfg.cleanup.PSObject.Properties['heldProbe'] -and $null -ne $Cfg.cleanup.heldProbe) { return [bool]$Cfg.cleanup.heldProbe }
    return $true
}

# "tên (pid N)" cho từng process, tối đa 3 tên trong câu.
function Format-RgHolders($Holders) {
    $h = @($Holders)
    $names = @($h | Select-Object -First 3 | ForEach-Object { "$($_.name) (pid $($_.pid))" })
    $s = $names -join ', '
    if ($h.Count -gt 3) { $s += " and $($h.Count - 3) more" }
    return $s
}

# Lý do chặn nếu có process khác đang giữ file của mục, hoặc $null. Chỉ áp cho mục xoá; không dùng cho kill/report.
function Get-RgHeldBlocker($Item, $Cfg) {
    if (-not (Test-RgHeldProbeEnabled $Cfg)) { return $null }
    if ([string]$Item.action -ne 'delete' -or -not [string]$Item.path) { return $null }
    $minAge = 0
    if ([string]$Item.kind -eq 'cache-aged' -and -not [bool]$Item.young) { $minAge = [int]$Item.ageDays }   # chỉ file đủ tuổi mới bị xoá
    $info = Get-RgHeldInfo -Path ([string]$Item.path) -MinAgeDays $minAge
    if (@($info.holders).Count -gt 0) { return "in use by $(Format-RgHolders $info.holders); skipped" }
    if (-not $info.ok) { Write-RgLog 'held-probe-unavailable' @{ path = [string]$Item.path } }
    return $null
}

# ---------- Kiểm tra trước khi thực thi (revalidate) ----------

# Trả về lý do chặn, hoặc $null nếu được phép xoá. Allowlist theo kind + root, KHÔNG chỉ dựa denylist.
function Get-RgDeleteBlocker($Item, $Cfg) {
    $path = [string]$Item.path
    if (-not [IO.Path]::IsPathRooted($path)) { return 'path is not absolute' }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($full -ne $path.TrimEnd('\')) { return 'path is not normalized' }
    if (-not (Test-Path -LiteralPath $full)) { return 'path no longer exists' }
    if (Test-RgReparse $full) { return 'path is a junction/symlink or unreadable' }
    $segs = $full.Split('\')
    foreach ($n in @($Cfg.protected.segments)) { if ($segs -contains $n) { return "protected path segment '$n'" } }

    $isDir = Test-Path -LiteralPath $full -PathType Container
    $leaf = $segs[$segs.Count - 1]
    $parent = Split-Path $full -Parent
    $roots = @(Get-RgWorkspaceRoots $Cfg.cleanup)
    # young = dưới sàn tuổi nhưng đã được đưa vào danh sách để người duyệt cân nhắc: chỉ bỏ sàn TUỔI cho 4 kind sinh lại được; mọi kiểm tra khác giữ nguyên.
    $young = [bool]$Item.young -and (@('dotnet-artifact', 'node_modules', 'temp-entry', 'cache-aged') -contains [string]$Item.kind)

    switch ([string]$Item.kind) {
        'dotnet-artifact' {
            if (-not $isDir -or -not ($leaf -ieq 'bin' -or $leaf -ieq 'obj')) { return 'not a bin/obj directory' }
            if (-not (Test-RgUnderRoot $full $roots)) { return 'outside configured workspaceRoots' }
            if (@([IO.Directory]::EnumerateFiles($parent, '*.*proj')).Count -eq 0) { return 'no project file next to directory' }
        }
        'node_modules' {
            if (-not $isDir -or $leaf -ine 'node_modules') { return 'not a node_modules directory' }
            if (-not (Test-RgUnderRoot $full $roots)) { return 'outside configured workspaceRoots' }
            if (-not (Test-Path -LiteralPath (Join-Path $parent 'package.json'))) { return 'no package.json next to directory' }
        }
        'temp-entry' {
            if ($parent.TrimEnd('\') -ine (Get-RgTempRoot $Cfg)) { return 'not a direct child of the temp root' }
            foreach ($pat in @($Cfg.cleanup.tempExclude)) { if ($leaf -like $pat) { return 'temp entry excluded by config' } }
            if (-not (Test-RgOwnedByCurrentUser $full)) { return 'owned by another account (needs elevation)' }
        }
        'cache-aged' {
            $known = @($Cfg.cleanup.cacheDirs.PSObject.Properties | ForEach-Object { (Expand-RgPath ([string]$_.Value)).TrimEnd('\') })
            if (-not $isDir -or -not ($known -contains $full)) { return 'not a configured cache directory' }
            if (-not $young -and [int]$Item.ageDays -lt [int]$Cfg.cleanup.cacheMinInactiveDays) { return 'inactivity threshold is below the policy floor' }
        }
        'stale-repo' {
            if (-not $isDir -or -not (Test-Path -LiteralPath (Join-Path $full '.git') -PathType Container)) { return 'not a git repo root' }
            if (-not (Test-RgUnderRoot $full $roots)) { return 'outside configured workspaceRoots' }
            if (Test-RgContainsScripts $full) { return 'contains the resource guard itself' }
            $sr = $Cfg.cleanup.staleRepo
            if (-not $sr) { return 'stale-repo is not configured' }
            $act = Get-RgRepoActivity $full ((Get-Date).ToUniversalTime().AddDays(-[int]$sr.minInactiveDays))
            if ($act.fresh) { return "source files modified within the last $([int]$sr.minInactiveDays) days" }
            $gs = Get-RgGitState $full
            if (-not $gs.safe) { return "repo $($gs.reason)" }
        }
        'large-item' {
            $li = $Cfg.cleanup.largeItem
            if (-not $li) { return 'large-item is not configured' }
            $okRoot = $false
            foreach ($lr in @($li.roots)) { if ($parent.TrimEnd('\') -ieq (Expand-RgPath ([string]$lr)).TrimEnd('\')) { $okRoot = $true } }
            if (-not $okRoot) { return 'not a direct child of a configured large-item root' }
            if ($isDir) {
                $st = Get-RgDirStats $full; $newest = $st.newestUtc
                $dt = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc; if ($dt -gt $newest) { $newest = $dt }
            } else {
                $fi = Get-Item -LiteralPath $full -Force; $newest = $fi.LastWriteTimeUtc
                if ($fi.LastAccessTimeUtc -gt $newest) { $newest = $fi.LastAccessTimeUtc }
            }
            if (((Get-Date).ToUniversalTime() - $newest).TotalDays -lt [int]$li.minInactiveDays) { return "touched within the last $([int]$li.minInactiveDays) days" }
        }
        'cluster-file' {
            # file cá nhân nằm trong một cụm của trợ lý (D5): chỉ file thường, dưới gốc kiểm kê KHÔNG phải "góc khuất", không dùng trong N ngày gần đây.
            if ($isDir) { return 'not a regular file' }
            $ic = Get-RgInventoryConfig $Cfg
            if (-not (Test-RgUnderRoot $full @($ic.roots))) { return 'outside the inventory roots' }
            $fi = Get-Item -LiteralPath $full -Force
            $idle = $fi.LastWriteTimeUtc; if ((Test-RgAtimeEnabled) -and $fi.LastAccessTimeUtc -gt $idle) { $idle = $fi.LastAccessTimeUtc }
            if (((Get-Date).ToUniversalTime() - $idle).TotalDays -lt [int]$ic.keepRecentDays) { return "touched within the last $([int]$ic.keepRecentDays) days" }
        }
        default { return "kind '$($Item.kind)' is not deletable" }
    }

    if (-not $young -and $Cfg.cleanup.minAgeDays.PSObject.Properties[[string]$Item.kind]) {
        $min = [int]$Cfg.cleanup.minAgeDays.([string]$Item.kind)
        if ($isDir) {
            $st = Get-RgDirStats $full
            $newest = $st.newestUtc
            $dt = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
            if ($dt -gt $newest) { $newest = $dt }
        } else { $newest = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc }
        if (((Get-Date).ToUniversalTime() - $newest).TotalDays -lt $min) { return "modified within the last $min days" }
    }
    return $null
}

function Get-RgKillBlocker($Item, $Cfg) {
    $procId = [int]$Item.pid
    if ($procId -eq $PID) { return 'refusing to kill the guard itself' }
    if (-not (Test-RgProcessIdentity $procId ([string]$Item.start) ([string]$Item.name))) {
        return 'PID is gone or was reused (start time / name mismatch)'
    }
    $group = Get-RgGroup ([string]$Item.name) '' $Cfg
    if (@($Cfg.kill.allowedGroups) -notcontains $group) { return "process group '$group' is protected" }
    $inLedger = @(Read-RgLedger | Where-Object { $_.pid -eq $procId -and $_.start -eq $Item.start })
    if ($inLedger.Count -eq 0) { return 'process was not registered by an agent' }
    if (Test-RgLedgerEntryExpired $inLedger[0] $Cfg) { return 'agent registration expired (agent is gone and no heartbeat within the ledger TTL)' }
    return $null
}

# ---------- Apply ----------

function Invoke-RgApply {
    param([string]$PlanId, [switch]$DryRun)
    $cfg = Get-RgConfig
    $plan = Read-RgPlan $PlanId
    $fail = { param($code, $msg) Write-RgLog 'apply-refused' @{ planId = $PlanId; code = $code; message = $msg }
        return [pscustomobject]@{ ok = $false; code = $code; message = $msg; results = @() } }

    if ($plan.status -eq 'applied') { return (& $fail 6 'plan was already applied') }
    if ($plan.approval.status -ne 'approved') { return (& $fail 4 'plan is not approved; nothing executed') }
    $h = Get-RgItemsHash $plan.items
    if ($h -ne $plan.itemsHash -or $h -ne $plan.approval.itemsHash) { return (& $fail 5 'plan items changed since approval; nothing executed') }

    # Chạy tiếp plan dở: mục mà journal đã đóng done/partial cho CHÍNH plan này thì không làm lại (vd. đã nén+xoá rồi người dùng khôi phục).
    $resuming = ($plan.status -eq 'applying')
    $doneTargets = @{}
    if ($resuming) {
        $closePhase = @{}
        $jall = @(Read-RgJournal)
        foreach ($e in $jall) { if ($e.phase -ne 'intent') { $closePhase[[string]$e.actionId] = [string]$e.phase } }
        foreach ($e in $jall) {
            if ($e.phase -eq 'intent' -and [string]$e.planId -eq $PlanId -and $closePhase.ContainsKey([string]$e.actionId) -and @('done', 'partial') -contains $closePhase[[string]$e.actionId]) { $doneTargets[[string]$e.target] = $true }
        }
    }
    if (-not $DryRun) {
        # 'applying' = đã bắt đầu thi hành; nếu process chết giữa chừng, chạy lại apply sẽ revalidate từng mục (mục đã xoá bị bỏ qua).
        if ($plan.status -eq 'applying') { Write-RgLog 'apply-resume' @{ planId = $PlanId } }
        $plan.status = 'applying'
        try { Save-RgPlan $plan } catch { return (& $fail 7 "cannot persist plan state, nothing executed: $($_.Exception.Message)") }
    }
    $results = @()
    $freed = 0L
    foreach ($id in @($plan.approval.approvedItemIds)) {
        $item = @($plan.items | Where-Object { $_.id -eq $id }) | Select-Object -First 1
        $r = [ordered]@{ id = $id; kind = $item.kind; action = $item.action; target = $(if ($item.action -eq 'kill') { "pid $($item.pid) $($item.name)" } else { $item.path }); outcome = ''; detail = ''; recovery = '' }
        $blocker = $null
        if ($item.action -eq 'delete') {
            $blocker = Get-RgDeleteBlocker $item $cfg
            # lớp chặn thứ hai: mục dưới sàn tuổi không bao giờ chạy theo plan do policy tự duyệt
            if (-not $blocker -and [bool]$item.young -and [string]$plan.approval.approvedBy -eq 'policy') { $blocker = 'below-age-floor item needs human approval (auto-clean refused)' }
            # C2: file đang được process khác mở => bỏ qua, ghi tên process (kiểm ngay trước khi xoá, không dựa vào kết quả quét cũ)
            if (-not $blocker) { $blocker = Get-RgHeldBlocker $item $cfg }
        }
        elseif ($item.action -eq 'kill') { $blocker = Get-RgKillBlocker $item $cfg }
        else { $blocker = 'report-only item' }
        if (-not $blocker -and $resuming -and $doneTargets.ContainsKey([string]$r.target)) { $blocker = 'already done in an earlier run of this plan (journal)' }

        if ($blocker) { $r.outcome = 'skipped'; $r.detail = $blocker }
        elseif ($DryRun) { $r.outcome = 'would-run' }
        else {
            $jid = $null; $freedBefore = $freed
            try {
                # ghi-trước: không ghi được intent thì KHÔNG thực thi mục này
                $jAct = if ($item.action -eq 'kill') { 'kill' } elseif ([bool]$item.archive -and (Test-RgArchivable ([string]$item.kind))) { 'archive' } else { 'delete' }
                $rec = if ($jAct -eq 'kill') { 'none' } elseif ($jAct -eq 'archive') { 'zip' } else { Get-RgKindRecovery ([string]$item.kind) }
                if ($rec -eq 'zip-optional') { $rec = 'permanent' }   # loại không sinh lại được, người duyệt chọn xoá không nén: ghi rõ là xoá vĩnh viễn
                $r.recovery = $rec
                $jid = Write-RgJournalIntent -Action $jAct -Kind ([string]$item.kind) -Target ([string]$r.target) -PlanId $PlanId -Extra ([ordered]@{ recovery = $rec; approvedBy = [string]$plan.approval.approvedBy })
                if ($item.action -eq 'kill') {
                    $kr = Stop-RgProcessVerified -ProcId ([int]$item.pid) -Start ([string]$item.start) -Name ([string]$item.name) -Cfg $cfg
                    if ($kr.ok) {
                        $r.outcome = 'done'
                        $r.detail = "stopped ($($kr.method)); verified exited" + $(if (@($kr.tree).Count -gt 1) { ", $(@($kr.tree).Count - 1) child process(es) too" } else { '' })
                        if (@($kr.skipped).Count -gt 0) { $r.detail += "; left $(@($kr.skipped).Count) child process(es) outside the allowed groups" }
                    } else { $r.outcome = 'failed'; $r.detail = [string]$kr.reason }
                } elseif ([bool]$item.archive -and (Test-RgArchivable ([string]$item.kind))) {
                    # nén zip cạnh mục + kiểm tra; chỉ khi zip hợp lệ mới xoá bản gốc. Zip lỗi => bản gốc nguyên vẹn.
                    $ar = New-RgArchive -Path ([string]$item.path)
                    if (-not $ar.ok) {
                        $r.outcome = 'failed'; $r.detail = "archive failed, original kept: $($ar.error)"
                    } else {
                        $isFile = -not (Test-Path -LiteralPath $item.path -PathType Container)
                        Add-RgArchiveRecord ([ordered]@{ id = (Get-RgSha256 ($ar.zip + '|' + (Get-RgNowStamp))).Substring(0, 12); zip = $ar.zip; original = [string]$item.path; kind = [string]$item.kind
                                isFile = $isFile; bytes = $ar.bytes; zipBytes = $ar.zipBytes; files = $ar.files; createdUtc = (Get-Date).ToUniversalTime().ToString('o') })
                        $rt = if ($isFile) {
                            $fi = New-Object IO.FileInfo([string]$item.path); if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
                            try { [IO.File]::Delete([string]$item.path); [pscustomobject]@{ removed = $true; failed = 0; firstError = '' } }
                            catch { [pscustomobject]@{ removed = $false; failed = 1; firstError = $_.Exception.Message } }
                        } else { Remove-RgTree -Path ([string]$item.path) }
                        $freed += [math]::Max(0L, [long]$ar.bytes - [long]$ar.zipBytes)
                        $sz = "$([math]::Round($ar.bytes / 1MB, 1)) MB -> $([math]::Round($ar.zipBytes / 1MB, 1)) MB"
                        if ($rt.removed) { $r.outcome = 'done'; $r.detail = "archived to $($ar.zip) ($sz) and deleted the original" }
                        else { $r.outcome = 'done'; $r.partial = $true; $r.detail = "archived to $($ar.zip) ($sz); $($rt.failed) entries of the original could not be deleted: $($rt.firstError)" }
                    }
                } elseif ($item.kind -eq 'cache-aged') {
                    # kiểm tra lại độ không hoạt động tại thời điểm apply; số byte giải phóng là số thực xoá được
                    $ag = Invoke-RgAgedFiles -Path ([string]$item.path) -Days ([int]$item.ageDays) -Delete
                    $freed += $ag.bytes
                    $r.detail = "deleted $($ag.count) files ($([math]::Round($ag.bytes / 1MB, 1)) MB), $($ag.failed) failed/locked"
                    if ($ag.firstError) { $r.detail += ": $($ag.firstError)" }
                    if ($ag.count -eq 0 -and $ag.failed -gt 0) { $r.outcome = 'failed' } else { $r.outcome = 'done' }
                    if ($ag.failed -gt 0) { $r.partial = $true }
                } else {
                    if (Test-Path -LiteralPath $item.path -PathType Container) {
                        $rt = Remove-RgTree -Path ([string]$item.path)
                        if ($rt.removed) {
                            $r.outcome = 'done'; $freed += [long]$item.sizeBytes
                        } else {
                            # một số mục bị từ chối (file bị khoá/ACL lạ): phần xoá được đã xoá, báo rõ phần còn lại
                            $freed += $rt.bytes
                            $r.detail = "deleted $($rt.count) files ($([math]::Round($rt.bytes / 1MB, 1)) MB), $($rt.failed) entries could not be deleted"
                            if ($rt.firstError) { $r.detail += ": $($rt.firstError)" }
                            if ($rt.count -eq 0) { $r.outcome = 'failed' } else { $r.outcome = 'done' }
                            $r.partial = $true   # xoá dở: phần còn lại sẽ hiện lại ở lượt quét sau (không có gì bị mất âm thầm)
                        }
                    } else {
                        $fi = New-Object IO.FileInfo([string]$item.path)
                        if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
                        [IO.File]::Delete([string]$item.path)
                        if (Test-Path -LiteralPath $item.path) { throw 'path still exists after delete' }
                        $r.outcome = 'done'
                        $freed += [long]$item.sizeBytes
                    }
                }
            } catch {
                $r.outcome = 'failed'; $r.detail = $_.Exception.Message
            }
            if ($jid) { Close-RgJournal $jid $(if ($r.outcome -eq 'failed') { 'failed' } elseif ($r.Contains('partial')) { 'partial' } else { 'done' }) ([string]$r.detail) ([long]($freed - $freedBefore)) }
        }
        $results += [pscustomobject]$r
        if (-not $DryRun) { Write-RgLog 'apply-item' @{ planId = $PlanId; item = $r } }
    }

    if (-not $DryRun) {
        $plan.status = 'applied'
        $plan.results = @($results)
        try { Save-RgPlan $plan } catch { Write-RgLog 'plan-save-error' @{ planId = $PlanId; error = [string]$_.Exception.Message } }   # việc đã làm xong; journal + log vẫn ghi lại kết quả
    }
    return [pscustomobject]@{
        ok = (@($results | Where-Object { $_.outcome -eq 'failed' }).Count -eq 0)
        code = 0; message = $(if ($DryRun) { 'dry run' } else { 'applied' }); freedBytes = $freed; results = $results
    }
}

# ---------- Ngưỡng trạng thái sửa được từ UI (P4 plan-ux-clarity) ----------
# Dạng vào/ra giống GET /api/settings: { ramAvailGB: { normalAbove, cautionFrom, restrictedFrom }, diskFreeGB: { normalAbove, cautionFrom }, commitPct: { restricted, critical } }.
# Cho phép gửi một phần; phần thiếu lấy từ $Cfg hiện tại. Trả về { ok; error; merged } (merged = ngưỡng đầy đủ sau khi gộp).
function Test-RgThresholdInput($In, $Cfg) {
    $cur = [ordered]@{
        ramAvailGB = [ordered]@{ normalAbove = [double]$Cfg.ram.normalAboveGB; cautionFrom = [double]$Cfg.ram.cautionFromGB; restrictedFrom = [double]$Cfg.ram.restrictedFromGB }
        diskFreeGB = [ordered]@{ normalAbove = [double]$Cfg.disk.normalAboveGB; cautionFrom = [double]$Cfg.disk.cautionFromGB }
        commitPct  = [ordered]@{ restricted = [double]$Cfg.commit.restrictedPct; critical = [double]$Cfg.commit.criticalPct }
    }
    $fail = { param($m) return [pscustomobject]@{ ok = $false; error = $m; merged = $null } }
    if ($null -eq $In) { return (& $fail 'Thiếu ngưỡng.') }
    foreach ($grp in @($cur.Keys)) {
        $g = $In.PSObject.Properties[$grp]
        if (-not $g -or $null -eq $g.Value) { continue }
        foreach ($k in @($cur[$grp].Keys)) {
            $p = $g.Value.PSObject.Properties[$k]
            if (-not $p -or $null -eq $p.Value) { continue }
            $d = 0.0
            if (-not [double]::TryParse(([string]$p.Value), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or [double]::IsNaN($d) -or [double]::IsInfinity($d)) { return (& $fail "Giá trị $grp.$k không phải số.") }
            $cur[$grp][$k] = $d
        }
    }
    $r = $cur.ramAvailGB; $d = $cur.diskFreeGB; $m = $cur.commitPct
    foreach ($v in @($r.normalAbove, $r.cautionFrom, $r.restrictedFrom, $d.normalAbove, $d.cautionFrom, $m.restricted, $m.critical)) { if ($v -le 0) { return (& $fail 'Ngưỡng phải là số dương.') } }
    if (-not ($r.normalAbove -gt $r.cautionFrom -and $r.cautionFrom -gt $r.restrictedFrom)) { return (& $fail 'RAM: mức Ổn phải lớn hơn Cần chú ý, và Cần chú ý lớn hơn Hạn chế.') }
    if ($r.normalAbove -gt 256) { return (& $fail 'RAM: ngưỡng Ổn tối đa 256 GB.') }
    if (-not ($d.normalAbove -gt $d.cautionFrom)) { return (& $fail 'Ổ đĩa: mức Ổn phải lớn hơn Cần chú ý.') }
    if ($d.normalAbove -gt 5000) { return (& $fail 'Ổ đĩa: ngưỡng Ổn tối đa 5000 GB.') }
    if (-not ($m.restricted -lt $m.critical)) { return (& $fail 'Bộ nhớ cam kết: mức Hạn chế phải nhỏ hơn Nguy cấp.') }
    if ($m.restricted -lt 50 -or $m.critical -gt 100) { return (& $fail 'Bộ nhớ cam kết: phần trăm phải nằm trong khoảng 50 đến 100.') }
    return [pscustomobject]@{ ok = $true; error = ''; merged = $cur }
}

# Nới lỏng = làm cho cảnh báo đến muộn hơn: ngưỡng "còn trống" thấp đi hoặc ngưỡng "% cam kết" cao lên. Dùng để quyết định có cần PIN khi tự động hoá đang Bật.
function Test-RgThresholdsLoosened($Old, $New) {
    foreach ($k in @('normalAbove', 'cautionFrom', 'restrictedFrom')) { if ([double]$New.ramAvailGB[$k] -lt [double]$Old.ramAvailGB[$k]) { return $true } }
    foreach ($k in @('normalAbove', 'cautionFrom')) { if ([double]$New.diskFreeGB[$k] -lt [double]$Old.diskFreeGB[$k]) { return $true } }
    foreach ($k in @('restricted', 'critical')) { if ([double]$New.commitPct[$k] -gt [double]$Old.commitPct[$k]) { return $true } }
    return $false
}

# Ghi ngưỡng đã gộp vào config.json của người dùng. Chỉ ghi phần người dùng đã đặt + ngưỡng này (không chép cả default vào file,
# để khoá mặc định mới ở bản sau vẫn có hiệu lực).
function Save-RgThresholds($Merged) {
    $user = Get-RgUserConfigRaw
    if ($null -eq $user) { $user = [pscustomobject]@{} }
    $setKey = { param($obj, $name, $val) if ($obj.PSObject.Properties[$name]) { $obj.$name = $val } else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $val } }
    $sect = { param($name) if (-not $user.PSObject.Properties[$name] -or $null -eq $user.$name) { & $setKey $user $name ([pscustomobject]@{}) }; return $user.$name }
    $r = & $sect 'ram'; $d = & $sect 'disk'; $c = & $sect 'commit'
    & $setKey $r 'normalAboveGB' $Merged.ramAvailGB.normalAbove; & $setKey $r 'cautionFromGB' $Merged.ramAvailGB.cautionFrom; & $setKey $r 'restrictedFromGB' $Merged.ramAvailGB.restrictedFrom
    & $setKey $d 'normalAboveGB' $Merged.diskFreeGB.normalAbove; & $setKey $d 'cautionFromGB' $Merged.diskFreeGB.cautionFrom
    & $setKey $c 'restrictedPct' $Merged.commitPct.restricted; & $setKey $c 'criticalPct' $Merged.commitPct.critical
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'config.json') (ConvertTo-Json -InputObject $user -Depth 12)
}
