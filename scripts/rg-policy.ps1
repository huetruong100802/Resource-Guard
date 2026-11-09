# rg-policy.ps1 - chính sách giữ/dọn, engine tự dọn và PIN (dot-source sau rg-common.ps1).
# Nguyên tắc: tool nắm sự thật, chính sách do người dùng đặt; xoá/kill luôn đi qua Invoke-RgApply (allowlist + revalidate).
# Mặc định mode = off. 'dry-run' chỉ ghi nhận việc SẼ làm. 'on' mới thật sự dọn, và bật/nới lỏng cần PIN.

$script:RgPolicyKinds = @('temp-entry', 'dotnet-artifact', 'cache-aged', 'node_modules', 'process')
$script:RgPolicyModes = @('off', 'dry-run', 'on')
$script:RgCatModes = @('auto', 'ask', 'keep')   # keep < ask < auto (độ tự động tăng dần)
$script:RgPinMaxFails = 5
$script:RgPinLockMin = 5

function Get-RgPolicyPath { return (Join-Path (Initialize-RgHome) 'state\policy.json') }
function Get-RgPinPath { return (Join-Path (Initialize-RgHome) 'state\pin.json') }
function Get-RgPinFailPath { return (Join-Path (Initialize-RgHome) 'state\pin-fail.json') }

function Get-RgDefaultPolicy {
    return [ordered]@{
        version = 1
        mode = 'off'
        diskTrigger = 'Critical'      # off | Caution | Critical  (trạng thái ổ đĩa kích hoạt dọn file)
        ramTrigger = 'Restricted'     # off | Restricted | Critical (trạng thái RAM kích hoạt kill tiến trình)
        cooldownMin = 30
        maxGBPerRun = 10
        targetFreeGB = 25             # dừng chọn thêm khi ước tính đã đủ trống
        drives = [ordered]@{}         # ghi đè theo ổ: { "D": { diskTrigger: off|Caution|Critical, targetFreeGB: n } }; thiếu thì dùng giá trị chung ở trên
        maxKillsPerRun = 5
        categories = [ordered]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'cache-aged' = 'ask'; 'node_modules' = 'ask'; 'process' = 'ask' }
        priority = @('temp-entry', 'dotnet-artifact', 'cache-aged', 'node_modules', 'process')
        protectPaths = @()
        protectProcesses = @()
        updatedUtc = $null
    }
}

function ConvertTo-RgStringList($V, [int]$Max = 200, [int]$MaxLen = 260) {
    $out = New-Object System.Collections.ArrayList
    foreach ($x in @($V)) {
        if ($null -eq $x) { continue }
        $s = ([string]$x).Trim()
        if (-not $s -or $s.Length -gt $MaxLen -or $s -match '[\x00-\x1f]') { continue }
        $dup = $false; foreach ($e in $out) { if ($e -ieq $s) { $dup = $true; break } }
        if (-not $dup -and $out.Count -lt $Max) { [void]$out.Add($s) }
    }
    return $out.ToArray()
}

# Chuẩn hoá + kiểm tra đầu vào policy (dùng cho cả file lẫn dữ liệu POST từ UI). Giá trị lạ bị bỏ/kẹp về mặc định.
function ConvertTo-RgPolicy($In) {
    $d = Get-RgDefaultPolicy
    $p = Get-RgDefaultPolicy
    if ($null -eq $In) { return $p }
    $get = { param($n) if ($In -is [System.Collections.IDictionary]) { if ($In.Contains($n)) { $In[$n] } else { $null } } elseif ($In.PSObject.Properties[$n]) { $In.$n } else { $null } }
    $m = [string](& $get 'mode'); if ($script:RgPolicyModes -contains $m) { $p.mode = $m }
    $v = [string](& $get 'diskTrigger'); if (@('off', 'Caution', 'Critical') -contains $v) { $p.diskTrigger = $v }
    $v = [string](& $get 'ramTrigger'); if (@('off', 'Restricted', 'Critical') -contains $v) { $p.ramTrigger = $v }
    $n = & $get 'cooldownMin'; if ($null -ne $n) { $p.cooldownMin = [int][math]::Min(1440, [math]::Max(1, [double]$n)) }
    $n = & $get 'maxGBPerRun'; if ($null -ne $n) { $p.maxGBPerRun = [double][math]::Min(500.0, [math]::Max(0.1, [double]$n)) }
    $n = & $get 'targetFreeGB'; if ($null -ne $n) { $p.targetFreeGB = [double][math]::Min(1000.0, [math]::Max(1.0, [double]$n)) }
    $n = & $get 'maxKillsPerRun'; if ($null -ne $n) { $p.maxKillsPerRun = [int][math]::Min(50, [math]::Max(0, [double]$n)) }
    $dv = & $get 'drives'
    if ($dv) {
        $prop = { param($o, $n) if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { $o[$n] } else { $null } } elseif ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
        $keys = if ($dv -is [System.Collections.IDictionary]) { @($dv.Keys) } else { @($dv.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($k in $keys) {
            $L = ([string]$k).Trim().TrimEnd(':').ToUpperInvariant()
            if ($L -notmatch '^[A-Z]$') { continue }
            $o = & $prop $dv $k
            $e = [ordered]@{}
            $t = [string](& $prop $o 'diskTrigger'); if (@('off', 'Caution', 'Critical') -contains $t) { $e['diskTrigger'] = $t }
            $g = & $prop $o 'targetFreeGB'; if ($null -ne $g -and [string]$g -ne '') { $e['targetFreeGB'] = [double][math]::Min(10000.0, [math]::Max(1.0, [double]$g)) }
            if ($e.Count -gt 0) { $p.drives[$L] = $e }
        }
    }
    $c = & $get 'categories'
    if ($c) {
        foreach ($k in $script:RgPolicyKinds) {
            $val = $null
            if ($c -is [System.Collections.IDictionary]) { if ($c.Contains($k)) { $val = [string]$c[$k] } }
            elseif ($c.PSObject.Properties[$k]) { $val = [string]$c.$k }
            if ($val -and ($script:RgCatModes -contains $val)) { $p.categories[$k] = $val }
        }
    }
    $pr = @(ConvertTo-RgStringList (& $get 'priority') 20 40 | Where-Object { $script:RgPolicyKinds -contains $_ })
    $final = New-Object System.Collections.ArrayList
    foreach ($k in $pr) { if ($final -notcontains $k) { [void]$final.Add($k) } }
    foreach ($k in $d.priority) { if ($final -notcontains $k) { [void]$final.Add($k) } }
    $p.priority = @($final.ToArray())
    $pp = @()
    foreach ($x in (ConvertTo-RgStringList (& $get 'protectPaths') 200 260)) {
        $t = (Expand-RgPath $x).Trim().TrimEnd('\')
        if ($t.Length -ge 4 -and [IO.Path]::IsPathRooted($t)) { $pp += $t }
    }
    $p.protectPaths = @($pp)
    $p.protectProcesses = @(ConvertTo-RgStringList (& $get 'protectProcesses') 200 80 | ForEach-Object { $_.ToLowerInvariant() })
    $u = & $get 'updatedUtc'; if ($u) { $p.updatedUtc = [string]$u }
    return $p
}

function Get-RgPolicy {
    $f = Get-RgPolicyPath
    if (Test-Path -LiteralPath $f) {
        try { return (ConvertTo-RgPolicy (ConvertFrom-Json (Read-RgFileShared $f))) } catch { Write-RgLog 'policy-read-error' ([string]$_) }
    }
    return (Get-RgDefaultPolicy)
}

function Save-RgPolicy($Policy) {
    $p = ConvertTo-RgPolicy $Policy
    $p.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-RgFileAtomic (Get-RgPolicyPath) (ConvertTo-Json -InputObject $p -Depth 5)
    return $p
}

# Policy mới có "chặt hơn hoặc bằng" cũ không? (chặt = ít tự động hơn / bảo vệ nhiều hơn). Chặt hơn thì không cần PIN.
function Test-RgPolicyTightening($Old, $New) {
    $rank = @{ 'off' = 0; 'dry-run' = 1; 'on' = 2 }
    if ($rank[[string]$New.mode] -gt $rank[[string]$Old.mode]) { return $false }
    $cr = @{ keep = 0; ask = 1; auto = 2 }
    foreach ($k in $script:RgPolicyKinds) { if ($cr[[string]$New.categories[$k]] -gt $cr[[string]$Old.categories[$k]]) { return $false } }
    $tr = @{ 'off' = 0; 'Critical' = 1; 'Restricted' = 2; 'Caution' = 3 }   # trigger càng sớm (Caution) càng mạnh tay
    if ($tr[[string]$New.diskTrigger] -gt $tr[[string]$Old.diskTrigger]) { return $false }
    $letters = @(@($Old.drives.Keys) + @($New.drives.Keys) | Select-Object -Unique)
    foreach ($L in $letters) {   # trigger hiệu lực của từng ổ (đã gồm giá trị chung): ổ nào bị nới thì không phải "chặt hơn"
        if ($tr[[string](Get-RgDrivePolicy $New $L).diskTrigger] -gt $tr[[string](Get-RgDrivePolicy $Old $L).diskTrigger]) { return $false }
    }
    if ($tr[[string]$New.ramTrigger] -gt $tr[[string]$Old.ramTrigger]) { return $false }
    if ([double]$New.maxGBPerRun -gt [double]$Old.maxGBPerRun) { return $false }
    if ([int]$New.maxKillsPerRun -gt [int]$Old.maxKillsPerRun) { return $false }
    if ([int]$New.cooldownMin -lt [int]$Old.cooldownMin) { return $false }
    foreach ($x in @($Old.protectPaths)) { if (@($New.protectPaths | Where-Object { $_ -ieq $x }).Count -eq 0) { return $false } }
    foreach ($x in @($Old.protectProcesses)) { if (@($New.protectProcesses | Where-Object { $_ -ieq $x }).Count -eq 0) { return $false } }
    return $true
}

# Chính sách hiệu lực của một ổ: ghi đè riêng của ổ đó nếu có, không thì giá trị chung.
function Get-RgDrivePolicy($Policy, [string]$Drive) {
    $t = [string]$Policy.diskTrigger; $g = [double]$Policy.targetFreeGB
    $o = $null
    if ($Policy.drives -is [System.Collections.IDictionary]) { if ($Policy.drives.Contains($Drive)) { $o = $Policy.drives[$Drive] } }
    elseif ($Policy.drives -and $Policy.drives.PSObject.Properties[$Drive]) { $o = $Policy.drives.$Drive }
    if ($o) {
        $ot = if ($o -is [System.Collections.IDictionary]) { $o['diskTrigger'] } else { $o.diskTrigger }
        $og = if ($o -is [System.Collections.IDictionary]) { $o['targetFreeGB'] } else { $o.targetFreeGB }
        if ($ot) { $t = [string]$ot }
        if ($null -ne $og) { $g = [double]$og }
    }
    return [pscustomobject]@{ diskTrigger = $t; targetFreeGB = $g; overridden = [bool]$o }
}

function Test-RgPolicyNeedsPin($Old, $New) {
    if ([string]$New.mode -ne 'on') { return $false }
    return (-not (Test-RgPolicyTightening $Old $New))
}

# ---------- Vùng bảo vệ ----------

function Test-RgPathProtected([string]$Path, $Policy) {
    $t = $Path.TrimEnd('\')
    foreach ($pp in @($Policy.protectPaths)) {
        $q = ([string]$pp).TrimEnd('\')
        if ($t -ieq $q) { return $true }
        if ($t.StartsWith($q + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }   # mục nằm trong vùng bảo vệ
        if ($q.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }   # xoá mục sẽ kéo theo vùng bảo vệ bên trong
    }
    return $false
}

function Test-RgProcessProtected([string]$Name, $Policy) {
    $n = $Name.ToLowerInvariant()
    foreach ($pat in @($Policy.protectProcesses)) {
        $s = ([string]$pat).ToLowerInvariant()
        if ($n -like $s -or $n -like ($s -replace '\.exe$', '')) { return $true }
    }
    return $false
}

# ---------- PIN (PBKDF2, đặt ở console, không bao giờ qua UI) ----------

function Get-RgPinHash([string]$Pin, [byte[]]$Salt, [int]$Iter) {
    $k = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pin, $Salt, $Iter)
    try { return [Convert]::ToBase64String($k.GetBytes(32)) } finally { $k.Dispose() }
}

function Test-RgPinConfigured { return (Test-Path -LiteralPath (Get-RgPinPath)) }

function Set-RgPin([string]$Pin) {
    if ($Pin.Length -lt 4 -or $Pin.Length -gt 64) { throw 'PIN phải dài 4-64 ký tự.' }
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
    $iter = 120000
    $o = [ordered]@{ v = 1; iter = $iter; salt = [Convert]::ToBase64String($salt); hash = (Get-RgPinHash $Pin $salt $iter); createdUtc = (Get-Date).ToUniversalTime().ToString('o') }
    Write-RgFileAtomic (Get-RgPinPath) (ConvertTo-Json -InputObject $o -Compress)
    Remove-Item -LiteralPath (Get-RgPinFailPath) -Force -ErrorAction SilentlyContinue
    Write-RgLog 'pin-set' @{}
}

# Trả {ok; locked; retryAfterSec}. Sai $script:RgPinMaxFails lần thì khoá $script:RgPinLockMin phút.
function Test-RgPin([string]$Pin) {
    $now = (Get-Date).ToUniversalTime()
    $fail = $null
    $ff = Get-RgPinFailPath
    if (Test-Path -LiteralPath $ff) { try { $fail = ConvertFrom-Json (Read-RgFileShared $ff) } catch { } }
    if ($fail -and $fail.lockUntilUtc) {
        $until = [datetime]::Parse([string]$fail.lockUntilUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
        if ($until -gt $now) { return [pscustomobject]@{ ok = $false; locked = $true; retryAfterSec = [int][math]::Ceiling(($until - $now).TotalSeconds) } }
    }
    if (-not (Test-RgPinConfigured)) { return [pscustomobject]@{ ok = $false; locked = $false; retryAfterSec = 0; notConfigured = $true } }
    $ok = $false
    try {
        $pj = ConvertFrom-Json (Read-RgFileShared (Get-RgPinPath))
        $calc = Get-RgPinHash $Pin ([Convert]::FromBase64String([string]$pj.salt)) ([int]$pj.iter)
        $a = [Text.Encoding]::ASCII.GetBytes($calc); $b = [Text.Encoding]::ASCII.GetBytes([string]$pj.hash)
        $diff = $a.Length -bxor $b.Length
        for ($i = 0; $i -lt [math]::Min($a.Length, $b.Length); $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
        $ok = ($diff -eq 0)
    } catch { $ok = $false }
    if ($ok) {
        Remove-Item -LiteralPath $ff -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ok = $true; locked = $false; retryAfterSec = 0 }
    }
    $cnt = 1; if ($fail -and $fail.count) { $cnt = [int]$fail.count + 1 }
    $rec = [ordered]@{ count = $cnt; lockUntilUtc = $null }
    $locked = $false
    if ($cnt -ge $script:RgPinMaxFails) { $rec.lockUntilUtc = $now.AddMinutes($script:RgPinLockMin).ToString('o'); $rec.count = 0; $locked = $true }
    Write-RgFileAtomic $ff (ConvertTo-Json -InputObject $rec -Compress)
    Write-RgLog 'pin-fail' @{ count = $cnt; locked = $locked }
    return [pscustomobject]@{ ok = $false; locked = $locked; retryAfterSec = $(if ($locked) { $script:RgPinLockMin * 60 } else { 0 }) }
}

# ---------- Job nền (scan / auto / agent): file tiến độ ----------

function Get-RgJobState([string]$File) {
    $p = Join-Path (Initialize-RgHome) ("state\" + $File)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $j = ConvertFrom-Json (Read-RgFileShared $p) } catch { return $null }
    if ($j.status -eq 'running' -and $j.pid -and -not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) {
        $j.status = 'error'; $j.message = 'tiến trình nền đã dừng đột ngột'
    }
    return $j
}

function Write-RgJobState([string]$File, $Obj) {
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) ("state\" + $File)) (ConvertTo-Json -InputObject $Obj -Compress -Depth 4)
}

# ---------- Engine chọn mục tự dọn ----------

function Get-RgStressInfo($Policy, $Cfg, $Snap) {
    $rk = @{ 'Normal' = 0; 'Caution' = 1; 'Restricted' = 2; 'Critical' = 3 }
    $rs = Get-RgRamState ([double]$Snap.availRamGB) $Cfg
    $ramStress = ([string]$Policy.ramTrigger -ne 'off') -and ($rk[$rs] -ge $rk[[string]$Policy.ramTrigger])
    # Áp lực ổ đĩa tính RIÊNG từng ổ (ngưỡng trạng thái + trigger + mục tiêu trống theo ổ). Snapshot cũ không có danh sách ổ thì coi như một ổ.
    $list = @($Snap.drives | Where-Object { $_ })
    if ($list.Count -eq 0 -and $null -ne $Snap.diskFreeGB) { $list = @([pscustomobject]@{ drive = [string]$Snap.diskDrive; freeGB = $Snap.diskFreeGB; totalGB = $null }) }
    $drv = @()
    foreach ($d in $list) {
        $L = [string]$d.drive
        $st = Get-RgDiskState $d.freeGB $Cfg $L
        $dp = Get-RgDrivePolicy $Policy $L
        $drv += [pscustomobject]@{
            drive = $L; freeGB = $d.freeGB; totalGB = $d.totalGB; state = $st; trigger = $dp.diskTrigger; targetFreeGB = $dp.targetFreeGB
            stress = (([string]$dp.diskTrigger -ne 'off') -and ($rk[$st] -ge $rk[[string]$dp.diskTrigger]))
        }
    }
    $ds = 'Normal'; foreach ($d in $drv) { if ($rk[$d.state] -gt $rk[$ds]) { $ds = $d.state } }
    $diskStress = [bool](@($drv | Where-Object { $_.stress }).Count -gt 0)
    return [pscustomobject]@{ diskState = $ds; ramState = $rs; diskStress = $diskStress; ramStress = $ramStress; diskFreeGB = $Snap.diskFreeGB; availRamGB = $Snap.availRamGB; drives = @($drv) }
}

# Chọn mục theo chính sách. Trả {selected; skipped}. Không xoá gì.
function Select-RgAutoItems($Candidates, $Policy, $Stress) {
    $sel = @(); $skip = @()
    $byDrive = @{}; foreach ($d in @($Stress.drives | Where-Object { $_ })) { $byDrive[[string]$d.drive] = $d }
    $legacy = ($byDrive.Count -eq 0)   # Stress dựng tay không có danh sách ổ: giữ cách tính một ổ như cũ
    $pri = @($Policy.priority)
    $eligible = @()
    foreach ($c in @($Candidates)) {
        $target = if ($c.kind -eq 'process') { "pid $($c.pid) $($c.name)" } else { [string]$c.path }
        $why = $null
        $stressWhy = $null
        if ($c.action -eq 'delete') {
            if ($legacy) { if (-not $Stress.diskStress) { $stressWhy = 'ổ đĩa chưa tới ngưỡng kích hoạt' } }
            else {
                $dl = Get-RgPathDrive ([string]$c.path)
                if (-not $dl) { $stressWhy = 'đường dẫn không nằm trên ổ cục bộ' }
                elseif (-not $byDrive.ContainsKey($dl)) { $stressWhy = "ổ ${dl}: không được giám sát" }
                elseif (-not $byDrive[$dl].stress) { $stressWhy = "ổ ${dl}: chưa tới ngưỡng kích hoạt" }
            }
        }
        if ($c.action -eq 'report') { $why = 'chỉ báo cáo' }
        elseif ($stressWhy) { $why = $stressWhy }
        elseif ($c.action -eq 'kill' -and -not $Stress.ramStress) { $why = 'RAM chưa tới ngưỡng kích hoạt' }
        elseif ([string]$Policy.categories[[string]$c.kind] -ne 'auto') { $why = "nhóm '$($c.kind)' đặt ở chế độ $($Policy.categories[[string]$c.kind])" }
        elseif ($c.action -eq 'delete' -and (Test-RgPathProtected ([string]$c.path) $Policy)) { $why = 'nằm trong vùng bảo vệ' }
        elseif ($c.action -eq 'kill' -and (Test-RgProcessProtected ([string]$c.name) $Policy)) { $why = 'tiến trình nằm trong vùng bảo vệ' }
        if ($why) { $skip += [pscustomobject]@{ target = $target; kind = $c.kind; reason = $why }; continue }
        $eligible += $c
    }
    $idx = { param($k) $i = [array]::IndexOf($pri, [string]$k); if ($i -lt 0) { 99 } else { $i } }
    $ordered = @($eligible | Sort-Object @{ Expression = { & $idx $_.kind } }, @{ Expression = { [long]$_.sizeBytes }; Descending = $true })
    $cumBy = @{}; $kills = 0
    $cap = [long]([double]$Policy.maxGBPerRun * 1GB)   # giới hạn GB mỗi lượt áp dụng cho TỪNG ổ
    foreach ($c in $ordered) {
        $target = if ($c.kind -eq 'process') { "pid $($c.pid) $($c.name)" } else { [string]$c.path }
        if ($c.action -eq 'kill') {
            if ($kills -ge [int]$Policy.maxKillsPerRun) { $skip += [pscustomobject]@{ target = $target; kind = $c.kind; reason = 'vượt số tiến trình tối đa mỗi lượt' }; continue }
            $kills++; $sel += $c; continue
        }
        $dk = if ($legacy) { '*' } else { [string](Get-RgPathDrive ([string]$c.path)) }
        if (-not $cumBy.ContainsKey($dk)) { $cumBy[$dk] = 0L }
        $tgt = if ($legacy) { [double]$Policy.targetFreeGB - [double]$Stress.diskFreeGB } else { [double]$byDrive[$dk].targetFreeGB - [double]$byDrive[$dk].freeGB }
        $need = [long]([math]::Max(0, $tgt) * 1GB)
        $lbl = if ($legacy) { '' } else { " (ổ $dk`:)" }
        if ($cumBy[$dk] -ge $need) { $skip += [pscustomobject]@{ target = $target; kind = $c.kind; reason = "đã đủ dung lượng mục tiêu$lbl" }; continue }
        if (($cumBy[$dk] + [long]$c.sizeBytes) -gt $cap) { $skip += [pscustomobject]@{ target = $target; kind = $c.kind; reason = "vượt giới hạn GB mỗi lượt$lbl" }; continue }
        $cumBy[$dk] = [long]$cumBy[$dk] + [long]$c.sizeBytes; $sel += $c
    }
    return [pscustomobject]@{ selected = @($sel); skipped = @($skip) }
}

function Get-RgAutoLastPath { return (Join-Path (Initialize-RgHome) 'state\auto-last.json') }

# Đến lúc chạy engine chưa? (server gọi mỗi tick; rẻ: chỉ đọc vài file nhỏ)
function Test-RgAutoDue($Policy, $Stress) {
    if ([string]$Policy.mode -eq 'off') { return $false }
    if (-not ($Stress.diskStress -or $Stress.ramStress)) { return $false }
    $job = Get-RgJobState 'auto.progress.json'
    if ($job -and $job.status -eq 'running') { return $false }
    $f = Get-RgAutoLastPath
    if (Test-Path -LiteralPath $f) {
        try {
            $l = ConvertFrom-Json (Read-RgFileShared $f)
            $t = [datetime]::Parse([string]$l.finishedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
            if (((Get-Date).ToUniversalTime() - $t).TotalMinutes -lt [double]$Policy.cooldownMin) { return $false }
        } catch { }
    }
    return $true
}

# Chạy một lượt. $Real = false => chỉ mô phỏng (kiểm blocker, không xoá). Trả bản ghi kết quả.
function Invoke-RgAutoRun {
    param($Candidates, $Policy, [bool]$Real, [string]$Trigger = 'auto', [bool]$AssumeStress = $false)
    $cfg = Get-RgConfig
    $snap = Get-RgSnapshot -SkipCpu
    $stress = Get-RgStressInfo $Policy $cfg $snap
    if ($AssumeStress) {   # chạy thử: coi như có áp lực để thấy engine SẼ chọn gì
        foreach ($d in @($stress.drives)) { if ([string]$d.trigger -ne 'off') { $d.stress = $true; $stress.diskStress = $true } }
        if (@($stress.drives).Count -eq 0 -and [string]$Policy.diskTrigger -ne 'off') { $stress.diskStress = $true }
        if ([string]$Policy.ramTrigger -ne 'off') { $stress.ramStress = $true }
    }
    $started = (Get-Date).ToUniversalTime().ToString('o')
    $pick = Select-RgAutoItems $Candidates $Policy $stress
    $rows = @(); $freed = 0L; $planId = $null
    if ($Real -and $pick.selected.Count -gt 0) {
        $plan = New-RgPlan -Items $pick.selected
        $planId = $plan.planId
        $ids = @($plan.items | Where-Object { $_.action -ne 'report' } | ForEach-Object { [int]$_.id })
        [void](Set-RgPlanApproval -PlanId $planId -ItemIds $ids -By 'policy')
        $res = Invoke-RgApply -PlanId $planId
        $freed = [long]$res.freedBytes
        $rows = @($res.results | ForEach-Object { [pscustomobject]@{ kind = $_.kind; target = $_.target; outcome = $_.outcome; detail = $_.detail } })
    } else {
        foreach ($c in $pick.selected) {
            $b = if ($c.action -eq 'kill') { Get-RgKillBlocker $c $cfg } else { Get-RgDeleteBlocker $c $cfg }
            $t = if ($c.kind -eq 'process') { "pid $($c.pid) $($c.name)" } else { [string]$c.path }
            $rows += [pscustomobject]@{ kind = $c.kind; target = $t; outcome = $(if ($b) { 'skipped' } else { 'would-run' }); detail = [string]$b; sizeBytes = [long]$c.sizeBytes }
        }
    }
    $rec = [ordered]@{
        startedUtc = $started; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); trigger = $Trigger
        mode = $(if ($Real) { 'on' } else { 'dry-run' }); planId = $planId
        stress = [ordered]@{ diskState = $stress.diskState; ramState = $stress.ramState; diskFreeGB = $stress.diskFreeGB; availRamGB = $stress.availRamGB
            drives = @($stress.drives | ForEach-Object { [ordered]@{ drive = $_.drive; freeGB = $_.freeGB; state = $_.state; trigger = $_.trigger; targetFreeGB = $_.targetFreeGB; stress = $_.stress } }) }
        freedBytes = $freed; items = $rows; skipped = @($pick.skipped | Select-Object -First 60); candidateCount = @($Candidates).Count
    }
    Write-RgFileAtomic (Get-RgAutoLastPath) (ConvertTo-Json -InputObject $rec -Depth 6 -Compress)
    Write-RgLog 'auto-run' ([ordered]@{ mode = $rec.mode; items = $rows.Count; freedBytes = $freed; trigger = $Trigger })
    return [pscustomobject]$rec
}

# ---------- Dọn mục cần quyền admin (chạy trong tiến trình elevated sau khi người dùng xác nhận UAC) ----------

# Nhận KEY (12 hex) từ danh sách ứng viên, nhưng KHÔNG tin đường dẫn trong đó: mỗi mục phải qua Get-RgElevatedDeleteBlocker
# (thư mục GUID trực tiếp dưới %TEMP%, đủ tuổi, không junction...) và không nằm trong vùng bảo vệ của người dùng.
# Ghi cleanup-last.json cùng định dạng rg-cleanup.ps1 để UI hiển thị chung.
function Invoke-RgElevatedClean {
    param([string[]]$Keys, [string]$TempRoot = '', [string]$By = 'ui-elevated')
    $cfg = Get-RgConfig; $policy = Get-RgPolicy
    if (-not $TempRoot) { $TempRoot = ([IO.Path]::GetTempPath()).TrimEnd('\') }
    $statePath = Join-Path (Initialize-RgHome) 'state'
    $cf = Join-Path $statePath 'scan-candidates.json'
    if (-not (Test-Path -LiteralPath $cf)) { throw 'Chưa có danh sách ứng viên; hãy quét trước.' }
    $cd = ConvertFrom-Json (Read-RgFileShared $cf)
    $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse([string]$cd.finishedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime()).TotalHours
    if ($age -gt 12) { throw 'Dữ liệu quét đã cũ hơn 12 giờ; hãy quét lại trước khi dọn.' }
    $want = @($Keys | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
    if ($want.Count -eq 0) { throw 'Không có key hợp lệ.' }
    $results = @(); $refused = @(); $freed = 0L
    foreach ($k in $want) {
        $c = @($cd.items | Where-Object { $_.key -eq $k }) | Select-Object -First 1
        if (-not $c) { $refused += [pscustomobject]@{ key = $k; reason = 'không còn trong danh sách ứng viên' }; continue }
        if ([string]$c.kind -ne 'temp-entry' -or -not [bool]$c.needsAdmin) { $refused += [pscustomobject]@{ key = $k; reason = 'mục này không thuộc nhóm cần quyền admin' }; continue }
        if (Test-RgPathProtected ([string]$c.path) $policy) { $refused += [pscustomobject]@{ key = $k; reason = 'nằm trong vùng bảo vệ' }; continue }
        $r = [ordered]@{ key = $k; kind = 'temp-entry'; target = [string]$c.path; outcome = ''; detail = '' }
        $b = Get-RgElevatedDeleteBlocker ([string]$c.path) $cfg $TempRoot
        if ($b) { $r.outcome = 'skipped'; $r.detail = $b }
        else {
            try {
                $rt = Remove-RgTree -Path ([string]$c.path)
                $freed += $rt.bytes
                if ($rt.removed) { $r.outcome = 'done'; $r.detail = "deleted $($rt.count) files ($([math]::Round($rt.bytes / 1MB, 1)) MB) with admin rights" }
                else {
                    $r.outcome = $(if ($rt.count -eq 0) { 'failed' } else { 'done' })
                    $r.detail = "deleted $($rt.count) files, $($rt.failed) entries could not be deleted: $($rt.firstError)"
                }
            } catch { $r.outcome = 'failed'; $r.detail = $_.Exception.Message }
        }
        $results += [pscustomobject]$r
    }
    $doneKeys = @($results | Where-Object { $_.outcome -eq 'done' -and (-not (Test-Path -LiteralPath $_.target)) } | ForEach-Object { $_.key })
    if ($doneKeys.Count -gt 0) {
        $cd.items = @($cd.items | Where-Object { $doneKeys -notcontains $_.key })
        Write-RgFileAtomic $cf (ConvertTo-Json -InputObject $cd -Depth 8 -Compress)
    }
    $rec = [ordered]@{ finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); by = $By; elevated = $true; planId = $null; freedBytes = $freed; results = $results; refused = $refused }
    Write-RgFileAtomic (Join-Path $statePath 'cleanup-last.json') (ConvertTo-Json -InputObject $rec -Depth 6 -Compress)
    Write-RgLog 'manual-cleanup' ([ordered]@{ by = $By; elevated = $true; items = $results.Count; refused = $refused.Count; freedBytes = $freed })
    return [pscustomobject]$rec
}
