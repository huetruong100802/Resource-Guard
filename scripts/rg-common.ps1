# rg-common.ps1 - thư viện dùng chung của Resource Guard (dot-source, không chạy trực tiếp).
# Tương thích Windows PowerShell 5.1 và PowerShell 7+. Không gọi LLM, không cần mạng.
# Thông điệp máy-đọc (reasons, blocker) viết bằng tiếng Anh ASCII để agent đọc ổn định.

$script:RgScriptsDir = $PSScriptRoot
$script:RgStates = @('Normal', 'Caution', 'Restricted', 'Critical')
. (Join-Path $PSScriptRoot 'rg-extra.ps1')   # repo cũ / mục lớn / app + nén zip tại chỗ + giải nén

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

function Get-RgConfig {
    $p = Join-Path (Get-RgHome) 'config.json'
    if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $script:RgScriptsDir '..\config.default.json' }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-RgLog([string]$Event, $Data) {
    try {
        $h = Initialize-RgHome
        $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); event = $Event; data = $Data }
        $file = Join-Path $h ('logs\rg-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject $rec -Depth 6 -Compress) -Encoding UTF8
    } catch { }
}

# Ghi file nguyên tử, chịu được việc có process khác đang đọc file đó (UI/server poll). Thử lại vài lần, cuối cùng ghi thẳng.
function Write-RgFileAtomic([string]$Path, [string]$Text) {
    $enc = New-Object Text.UTF8Encoding($false)
    for ($i = 0; $i -lt 5; $i++) {
        $tmp = "$Path.$PID.tmp"
        try {
            [IO.File]::WriteAllText($tmp, $Text, $enc)
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds (40 * ($i + 1)) }
    }
    Remove-Item -LiteralPath "$Path.$PID.tmp" -Force -ErrorAction SilentlyContinue
    try { [IO.File]::WriteAllText($Path, $Text, $enc) } catch { }
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
function Get-RgScanMaxAgeHours { return 12 }
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
    if ($null -ne $LastAutoStart -and ($Now - [datetime]$LastAutoStart).TotalMinutes -lt $MinGapMinutes) { return (NoScan 'Vừa quét nền cách đây chưa tới 10 phút') }

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
    $p = Get-RgLedgerPath
    $tmp = "$p.tmp"
    Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject @($Entries) -Depth 5) -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $p -Force
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
    }
    $keep = @(Read-RgLedger | Where-Object {
            -not ($_.pid -eq $entry.pid -and $_.start -eq $entry.start) -and
            (Test-RgProcessIdentity ([int]$_.pid) ([string]$_.start) ([string]$_.name))
        })
    Write-RgLedger ($keep + [pscustomobject]$entry)
    Write-RgLog 'register' $entry
    return [pscustomobject]$entry
}

# Process trong ledger còn sống nhưng process sở hữu (agent) đã chết => orphan chắc chắn của agent.
function Get-RgLedgerOrphans {
    $out = @()
    foreach ($e in (Read-RgLedger)) {
        $alive = Test-RgProcessIdentity ([int]$e.pid) ([string]$e.start) ([string]$e.name)
        if (-not $alive) { continue }
        $ownerAlive = $false
        if ($e.ownerStart) { $ownerAlive = [bool](Test-RgProcessIdentity ([int]$e.ownerPid) ([string]$e.ownerStart) '') }
        if (-not $ownerAlive) { $out += $e }
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
    param([string]$Task = 'session', $Snapshot = $null, $Table = $null)
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
    $projState = Get-RgRamState ($Snapshot.availRamGB - $est) $cfg
    $state = Get-RgWorstState @($ramState, $diskState, $commitState, $projState)

    if ($ramState -ne 'Normal') { [void]$reasons.Add("available RAM $($Snapshot.availRamGB)GB -> $ramState") }
    foreach ($ds in $driveStates) { if ($ds.state -ne 'Normal') { [void]$reasons.Add("disk $($ds.drive): free $($ds.freeGB)GB -> $($ds.state)") } }
    if ($commitState -ne 'Normal') { [void]$reasons.Add("commit charge $($Snapshot.commitPct)% -> $commitState") }
    if ($est -gt 0 -and $projState -ne $ramState) { [void]$reasons.Add("projected RAM after '$Task' (~${est}GB) -> $projState") }

    $heavy = @(Get-RgHeavyRoots $Table $cfg)
    $pol = $cfg.policy.$state
    $decision = 'allow'

    if ($Task -eq 'build' -or $Task -eq 'test') {
        if ($pol.heavy -eq 'deny') {
            $decision = 'deny'
            [void]$reasons.Add("state $state blocks new heavy tasks")
        } elseif ($heavy.Count -ge [int]$pol.maxHeavy) {
            $decision = 'deny'
            [void]$reasons.Add("concurrency budget reached ($($heavy.Count)/$($pol.maxHeavy) heavy tasks running)")
        } elseif ($state -ne 'Normal') { $decision = 'warn' }
    } elseif ($Task -eq 'subagent') {
        $decision = [string]$pol.subagent
        if ($decision -eq 'deny') { [void]$reasons.Add("state $state blocks new subagents") }
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
        heavyRunning = $heavy.Count
        maxHeavy     = [int]$pol.maxHeavy
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

# Dựng biên lai cho MỘT mục (hashtable từ New-RgItem hoặc object đọc từ scan-candidates.json).
# Trả về [ordered]@{ why; impact; regen; regenHint; riskLevel }.
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
    return [ordered]@{ why = $why; impact = $impact; regen = $regen; regenHint = $regenHint; riskLevel = $risk }
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
    Set-Content -LiteralPath (Get-RgPlanPath $Plan.planId) -Value (ConvertTo-Json -InputObject $Plan -Depth 8) -Encoding UTF8
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

    $results = @()
    $freed = 0L
    foreach ($id in @($plan.approval.approvedItemIds)) {
        $item = @($plan.items | Where-Object { $_.id -eq $id }) | Select-Object -First 1
        $r = [ordered]@{ id = $id; kind = $item.kind; action = $item.action; target = $(if ($item.action -eq 'kill') { "pid $($item.pid) $($item.name)" } else { $item.path }); outcome = ''; detail = '' }
        $blocker = $null
        if ($item.action -eq 'delete') {
            $blocker = Get-RgDeleteBlocker $item $cfg
            # lớp chặn thứ hai: mục dưới sàn tuổi không bao giờ chạy theo plan do policy tự duyệt
            if (-not $blocker -and [bool]$item.young -and [string]$plan.approval.approvedBy -eq 'policy') { $blocker = 'below-age-floor item needs human approval (auto-clean refused)' }
        }
        elseif ($item.action -eq 'kill') { $blocker = Get-RgKillBlocker $item $cfg }
        else { $blocker = 'report-only item' }

        if ($blocker) { $r.outcome = 'skipped'; $r.detail = $blocker }
        elseif ($DryRun) { $r.outcome = 'would-run' }
        else {
            try {
                if ($item.action -eq 'kill') {
                    Stop-Process -Id ([int]$item.pid) -Force -ErrorAction Stop
                    $r.outcome = 'done'
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
                        else { $r.outcome = 'done'; $r.detail = "archived to $($ar.zip) ($sz); $($rt.failed) entries of the original could not be deleted: $($rt.firstError)" }
                    }
                } elseif ($item.kind -eq 'cache-aged') {
                    # kiểm tra lại độ không hoạt động tại thời điểm apply; số byte giải phóng là số thực xoá được
                    $ag = Invoke-RgAgedFiles -Path ([string]$item.path) -Days ([int]$item.ageDays) -Delete
                    $freed += $ag.bytes
                    $r.detail = "deleted $($ag.count) files ($([math]::Round($ag.bytes / 1MB, 1)) MB), $($ag.failed) failed/locked"
                    if ($ag.firstError) { $r.detail += ": $($ag.firstError)" }
                    if ($ag.count -eq 0 -and $ag.failed -gt 0) { $r.outcome = 'failed' } else { $r.outcome = 'done' }
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
        }
        $results += [pscustomobject]$r
        if (-not $DryRun) { Write-RgLog 'apply-item' @{ planId = $PlanId; item = $r } }
    }

    if (-not $DryRun) {
        $plan.status = 'applied'
        $plan.results = @($results)
        Save-RgPlan $plan
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

# Ghi ngưỡng đã gộp vào config.json của người dùng (toàn bộ cấu hình, vì Get-RgConfig đọc đúng một file).
function Save-RgThresholds($Merged) {
    $cfg = Get-RgConfig
    $cfg.ram.normalAboveGB = $Merged.ramAvailGB.normalAbove; $cfg.ram.cautionFromGB = $Merged.ramAvailGB.cautionFrom; $cfg.ram.restrictedFromGB = $Merged.ramAvailGB.restrictedFrom
    $cfg.disk.normalAboveGB = $Merged.diskFreeGB.normalAbove; $cfg.disk.cautionFromGB = $Merged.diskFreeGB.cautionFrom
    $cfg.commit.restrictedPct = $Merged.commitPct.restricted; $cfg.commit.criticalPct = $Merged.commitPct.critical
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'config.json') (ConvertTo-Json -InputObject $cfg -Depth 12)
}
