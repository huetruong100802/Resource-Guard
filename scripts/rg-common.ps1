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

    $drive = ([string]$cfg.disk.drive).TrimEnd(':', '\')
    $diskFree = $null
    try { $diskFree = [math]::Round((New-Object IO.DriveInfo($drive)).AvailableFreeSpace / 1GB, 2) } catch { }

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
        if ($raw -and $raw.Trim()) { return @(ConvertFrom-Json $raw) }
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

function Get-RgDiskState($FreeGB, $Cfg) {
    if ($null -eq $FreeGB) { return 'Normal' }
    if ([double]$FreeGB -gt [double]$Cfg.disk.normalAboveGB) { return 'Normal' }
    if ([double]$FreeGB -ge [double]$Cfg.disk.cautionFromGB) { return 'Caution' }
    return 'Critical'
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
    $diskState = Get-RgDiskState $Snapshot.diskFreeGB $cfg
    $commitState = Get-RgCommitState $Snapshot.commitPct $cfg
    if ($null -eq $Snapshot.diskFreeGB) { [void]$reasons.Add('disk free space unknown') }

    $est = 0.0
    if ($cfg.estimateGB.PSObject.Properties[$Task]) { $est = [double]$cfg.estimateGB.$Task }
    $projState = Get-RgRamState ($Snapshot.availRamGB - $est) $cfg
    $state = Get-RgWorstState @($ramState, $diskState, $commitState, $projState)

    if ($ramState -ne 'Normal') { [void]$reasons.Add("available RAM $($Snapshot.availRamGB)GB -> $ramState") }
    if ($diskState -ne 'Normal') { [void]$reasons.Add("disk $($Snapshot.diskDrive): free $($Snapshot.diskFreeGB)GB -> $diskState") }
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
        [bool]$NeedsAdmin = $false, [bool]$Archive = $false)
    return [ordered]@{
        id = 0; kind = $Kind; action = $Action; level = $Level; path = $Path; pid = $ProcId; start = $Start
        name = $Name; sizeBytes = $SizeBytes; ageDays = $AgeDays; newestWriteUtc = $NewestUtc; reason = $Reason; risk = $Risk
        needsAdmin = $NeedsAdmin; archive = $Archive
    }
}

function Get-RgCandidates {
    $cfg = Get-RgConfig
    $now = (Get-Date).ToUniversalTime()
    $items = @()

    # 1) Artifact trong workspace: bin/obj, node_modules (đủ tuổi mới đề xuất)
    $roots = @($cfg.cleanup.workspaceRoots | ForEach-Object { Expand-RgPath $_ })
    foreach ($a in (Find-RgWorkspaceArtifacts $roots ([int]$cfg.cleanup.maxDepth))) {
        $st = Get-RgDirStats $a.Path
        $dirTime = (Get-Item -LiteralPath $a.Path -Force).LastWriteTimeUtc
        $newest = $st.newestUtc; if ($dirTime -gt $newest) { $newest = $dirTime }
        $ageDays = [math]::Floor(($now - $newest).TotalDays)
        $min = [int]$cfg.cleanup.minAgeDays.($a.Kind)
        if ($ageDays -lt $min) { continue }
        if ($a.Kind -eq 'dotnet-artifact') {
            $items += New-RgItem -Kind $a.Kind -Action 'delete' -Level 1 -Path $a.Path -SizeBytes $st.bytes -NewestUtc (ConvertTo-RgStamp $newest) `
                -Reason "build output untouched for $ageDays days (regenerated by next build)" -Risk 'low'
        } else {
            $items += New-RgItem -Kind $a.Kind -Action 'delete' -Level 2 -Path $a.Path -SizeBytes $st.bytes -NewestUtc (ConvertTo-RgStamp $newest) `
                -Reason "node_modules untouched for $ageDays days (restore with package manager)" -Risk 'medium: needs reinstall + network'
        }
    }

    # 2) Temp entries cũ (top N theo dung lượng)
    $tempRoot = Get-RgTempRoot $cfg
    $temp = @()
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
            if ($ageDays -lt [int]$cfg.cleanup.minAgeDays.'temp-entry') { continue }
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

    # 3) Cache dùng chung: chỉ file không hoạt động >= N ngày (cần duyệt)
    $cacheDays = [int]$cfg.cleanup.cacheMinInactiveDays
    foreach ($prop in $cfg.cleanup.cacheDirs.PSObject.Properties) {
        $p = (Expand-RgPath ([string]$prop.Value)).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if (Test-RgReparse $p) { continue }
        $ag = Invoke-RgAgedFiles -Path $p -Days $cacheDays
        if ($ag.bytes -lt ([long]$cfg.cleanup.minCacheMB * 1MB)) { continue }
        $items += New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $p -SizeBytes $ag.bytes -AgeDays $cacheDays `
            -Reason "$($prop.Name): $($ag.count) files not written or accessed for >= $cacheDays days; re-downloaded on demand" -Risk 'medium: slow next restore, needs network'
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
    return $items
}

# ---------- Plan ----------

function Get-RgItemsHash($Items) {
    $lines = @(foreach ($i in @($Items)) {
            '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $i.id, $i.kind, $i.action, $i.path, $i.pid, $i.start, $i.name, $i.sizeBytes, $i.ageDays, [bool]$i.archive
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
    $roots = @($Cfg.cleanup.workspaceRoots | ForEach-Object { Expand-RgPath $_ })

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
            if ([int]$Item.ageDays -lt [int]$Cfg.cleanup.cacheMinInactiveDays) { return 'inactivity threshold is below the policy floor' }
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

    if ($Cfg.cleanup.minAgeDays.PSObject.Properties[[string]$Item.kind]) {
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
        if ($item.action -eq 'delete') { $blocker = Get-RgDeleteBlocker $item $cfg }
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
