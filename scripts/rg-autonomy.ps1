# rg-autonomy.ps1 - action registry, mức tự chủ L0-L3 theo nhóm, banner/anti-lặp, nâng-hạ mức theo số liệu, dừng khẩn cấp (E1-E4).
# Dot-source từ cuối rg-policy.ps1. Nguyên tắc: agent chỉ ĐỀ XUẤT (chọn id action + tham số); Invoke-RgAction là cửa duy nhất đi vào Policy Engine,
# và mọi hành động vẫn đi qua plan -> approve -> Invoke-RgApply (allowlist + revalidate + vùng bảo vệ + journal). Mức tự chủ chỉ có thể HẠ miễn phí;
# nâng lên L3 cần PIN. Nhóm có file cá nhân hoặc tiến trình bị chặn trần ở L2 (luôn chờ người duyệt).

$script:RgLevels = @('L0', 'L1', 'L2', 'L3')
$script:RgAutonomyGroups = [ordered]@{
    'dev-cache'         = [pscustomobject]@{ id = 'dev-cache'; label = 'Cache công cụ dev đủ tuổi'; cap = 'L3'; kinds = @('cache-aged'); legacyCat = 'cache-aged' }
    'temp-files'        = [pscustomobject]@{ id = 'temp-files'; label = 'Tệp tạm của hệ thống'; cap = 'L3'; kinds = @('temp-entry'); legacyCat = 'temp-entry' }
    'build-artifacts'   = [pscustomobject]@{ id = 'build-artifacts'; label = 'Thư mục build (bin/obj, node_modules)'; cap = 'L2'; kinds = @('dotnet-artifact', 'node_modules'); legacyCat = 'dotnet-artifact' }
    'downloads-clean'   = [pscustomobject]@{ id = 'downloads-clean'; label = 'Bộ cài và file tạm đã tải'; cap = 'L2'; kinds = @(); legacyCat = '' }
    'personal-compress' = [pscustomobject]@{ id = 'personal-compress'; label = 'Nén file cá nhân lâu không dùng'; cap = 'L2'; kinds = @(); legacyCat = '' }
    'process-priority'  = [pscustomobject]@{ id = 'process-priority'; label = 'Hạ ưu tiên CPU tiến trình nền'; cap = 'L2'; kinds = @(); legacyCat = '' }
    'process-end'       = [pscustomobject]@{ id = 'process-end'; label = 'Kết thúc tiến trình build/test/dev'; cap = 'L2'; kinds = @(); legacyCat = 'process' }
}
$script:RgLevelText = [ordered]@{
    L0 = 'Tắt: trợ lý không đụng tới và không nhắc về nhóm này.'
    L1 = 'Đề xuất: chỉ báo cáo; không làm gì khi bạn chưa bấm.'
    L2 = 'Chờ duyệt: trợ lý chuẩn bị sẵn, bạn bấm một lần là làm.'
    L3 = 'Tự động: tự làm khi máy có áp lực, trong ngân sách, có biên lai và hoàn tác được nếu loại này hoàn tác được.'
}

function Get-RgLevelRank([string]$L) { $i = [array]::IndexOf($script:RgLevels, $L); if ($i -lt 0) { return 1 } else { return $i } }

# Chuẩn hoá khối autonomy của policy: chỉ nhóm biết trước, mức L0-L3, bị kẹp theo trần của nhóm. Trả hashtable (có thể rỗng).
function ConvertTo-RgAutonomy($In) {
    $out = [ordered]@{}
    if ($null -eq $In) { return $out }
    $keys = if ($In -is [System.Collections.IDictionary]) { @($In.Keys) } else { @($In.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($k in $keys) {
        $g = $script:RgAutonomyGroups[[string]$k]
        if (-not $g) { continue }
        $v = [string]$(if ($In -is [System.Collections.IDictionary]) { $In[$k] } else { $In.$k })
        $v = $v.Trim().ToUpperInvariant()
        if ($script:RgLevels -notcontains $v) { continue }
        if ((Get-RgLevelRank $v) -gt (Get-RgLevelRank $g.cap)) { $v = [string]$g.cap }
        $out[[string]$k] = $v
    }
    return $out
}

function Get-RgAutonomyExplicit($Policy) {
    $a = $null
    if ($Policy -is [System.Collections.IDictionary]) { if ($Policy.Contains('autonomy')) { $a = $Policy['autonomy'] } }
    elseif ($Policy -and $Policy.PSObject.Properties['autonomy']) { $a = $Policy.autonomy }
    return (ConvertTo-RgAutonomy $a)
}

# Mức hiệu lực của một nhóm: { level; explicit; cap; source }.
#   Có đặt tường minh -> dùng. Không đặt: nhóm KHÔNG có category cũ -> L1; nhóm có category cũ thì kế thừa (auto=L3, ask=L2, keep=L0) để không đổi hành vi cũ.
function Get-RgGroupLevel($Policy, [string]$Group) {
    $g = $script:RgAutonomyGroups[$Group]
    if (-not $g) { return [pscustomobject]@{ level = 'L0'; explicit = $false; cap = 'L0'; source = 'unknown' } }
    $ex = Get-RgAutonomyExplicit $Policy
    if ($ex.Contains($Group)) { return [pscustomobject]@{ level = [string]$ex[$Group]; explicit = $true; cap = [string]$g.cap; source = 'autonomy' } }
    $lv = 'L1'; $src = 'default'
    if ($g.legacyCat) {
        $cat = $null
        try { $cat = [string]$Policy.categories[[string]$g.legacyCat] } catch { }
        if ($cat -eq 'auto') { $lv = 'L3'; $src = 'legacy' } elseif ($cat -eq 'ask') { $lv = 'L2'; $src = 'legacy' } elseif ($cat -eq 'keep') { $lv = 'L0'; $src = 'legacy' }
    }
    if ((Get-RgLevelRank $lv) -gt (Get-RgLevelRank $g.cap)) { $lv = [string]$g.cap }
    return [pscustomobject]@{ level = $lv; explicit = $false; cap = [string]$g.cap; source = $src }
}

# Policy hiệu lực cho engine chọn mục: nhóm đặt tường minh thì quyết định category cũ của các kind thuộc nhóm (L0=keep, L1/L2=ask, L3=auto).
# Không có autonomy tường minh -> trả đúng policy đầu vào (hành vi cũ giữ nguyên).
function Get-RgEffectivePolicy($Policy) {
    $ex = Get-RgAutonomyExplicit $Policy
    if ($ex.Count -eq 0) { return $Policy }
    $cats = [ordered]@{}
    foreach ($k in $script:RgPolicyKinds) { try { $cats[$k] = [string]$Policy.categories[$k] } catch { $cats[$k] = 'ask' } }
    foreach ($gid in @($ex.Keys)) {
        $g = $script:RgAutonomyGroups[$gid]
        $cat = switch ([string]$ex[$gid]) { 'L0' { 'keep' } 'L3' { 'auto' } default { 'ask' } }
        foreach ($kd in @($g.kinds)) { if ($cats.Contains($kd)) { $cats[$kd] = $cat } }
        if ($gid -eq 'process-end' -and $cats.Contains('process')) { $cats['process'] = $cat }
    }
    $o = [ordered]@{}
    if ($Policy -is [System.Collections.IDictionary]) { foreach ($k in $Policy.Keys) { $o[$k] = $Policy[$k] } } else { foreach ($pr in $Policy.PSObject.Properties) { $o[$pr.Name] = $pr.Value } }
    $o['categories'] = $cats
    return [pscustomobject]$o
}

function Test-RgAutonomyRaised($Old, $New) {
    $a = Get-RgAutonomyExplicit $Old; $b = Get-RgAutonomyExplicit $New
    foreach ($gid in $script:RgAutonomyGroups.Keys) {
        $o = (Get-RgGroupLevel $Old $gid).level; $n = (Get-RgGroupLevel $New $gid).level
        if ((Get-RgLevelRank $n) -gt (Get-RgLevelRank $o)) { return $true }
    }
    return $false
}
# Nâng một nhóm lên L3 phải có PIN (nâng lên L1/L2 thì không: vẫn chờ người bấm).
function Test-RgAutonomyNeedsPin($Old, $New) {
    foreach ($gid in $script:RgAutonomyGroups.Keys) {
        $o = (Get-RgGroupLevel $Old $gid).level; $n = (Get-RgGroupLevel $New $gid).level
        if ($n -eq 'L3' -and $o -ne 'L3') { return $true }
    }
    return $false
}

function Get-RgAutonomyView($Policy = $null) {
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    return @($script:RgAutonomyGroups.Keys | ForEach-Object {
            $g = $script:RgAutonomyGroups[$_]; $lv = Get-RgGroupLevel $Policy $_
            [ordered]@{ id = $g.id; label = $g.label; cap = $g.cap; level = $lv.level; explicit = $lv.explicit; source = $lv.source; text = [string]$script:RgLevelText[$lv.level]
                levels = @($script:RgLevels | Where-Object { (Get-RgLevelRank $_) -le (Get-RgLevelRank $g.cap) } | ForEach-Object { [ordered]@{ level = $_; text = [string]$script:RgLevelText[$_] } }) }
        })
}

# ---------- E1: action registry ----------
# permission = mức tối thiểu của nhóm để một tác nhân KHÔNG phải người (agent/policy) tự thi hành. Chỉ 'L3' mới tự chạy; thấp hơn thì chờ người bấm.
$script:RgActions = [ordered]@{
    'clean-cache'     = [pscustomobject]@{ id = 'clean-cache'; group = 'dev-cache'; permission = 'L3'; reversible = $false; needsPin = $false; params = [ordered]@{ key = 'key12' }; label = 'Dọn một mục cache đủ tuổi' }
    'archive-cluster' = [pscustomobject]@{ id = 'archive-cluster'; group = 'personal-compress'; permission = 'L2'; reversible = $true; needsPin = $false; params = [ordered]@{ clusterId = 'key12' }; label = 'Nén một cụm tệp (zip có kiểm tra)' }
    'clean-cluster'   = [pscustomobject]@{ id = 'clean-cluster'; group = 'downloads-clean'; permission = 'L2'; reversible = $false; needsPin = $false; params = [ordered]@{ clusterId = 'key12' }; label = 'Xoá một cụm bộ cài / file tạm đã tải' }
    'lower-priority'  = [pscustomobject]@{ id = 'lower-priority'; group = 'process-priority'; permission = 'L2'; reversible = $true; needsPin = $false; params = [ordered]@{ pid = 'pid'; start = 'stamp'; level = 'level' }; label = 'Hạ / trả ưu tiên CPU của một tiến trình' }
    'end-process'     = [pscustomobject]@{ id = 'end-process'; group = 'process-end'; permission = 'L2'; reversible = $false; needsPin = $true; params = [ordered]@{ pid = 'pid'; start = 'stamp' }; label = 'Kết thúc một tiến trình đủ điều kiện' }
}

function Get-RgActionList { return @($script:RgActions.Values | ForEach-Object { [ordered]@{ id = $_.id; group = $_.group; permission = $_.permission; reversible = $_.reversible; needsPin = $_.needsPin; params = @($_.params.Keys); label = $_.label } }) }

function Test-RgActionParams($Action, $Params) {
    $keys = if ($Params -is [System.Collections.IDictionary]) { @($Params.Keys) } elseif ($Params) { @($Params.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
    foreach ($k in $keys) { if (-not $Action.params.Contains([string]$k)) { return "tham số lạ: $k" } }
    foreach ($k in $Action.params.Keys) {
        $v = $(if ($Params -is [System.Collections.IDictionary]) { $Params[$k] } elseif ($Params -and $Params.PSObject.Properties[$k]) { $Params.$k } else { $null })
        $s = [string]$v
        switch ($Action.params[$k]) {
            'key12' { if ($s -notmatch '^[0-9a-f]{12}$') { return "tham số $k phải là mã 12 ký tự hex" } }
            'pid' { $n = 0; if (-not [int]::TryParse($s, [ref]$n) -or $n -le 4) { return "tham số $k không phải PID hợp lệ" } }
            'stamp' { if ($s -notmatch '^\d{8}T\d{6}Z$') { return "tham số $k sai định dạng thời điểm khởi động" } }
            'level' { if (@('below', 'normal') -notcontains $s) { return "tham số $k chỉ nhận below hoặc normal" } }
        }
    }
    return ''
}

function Read-RgCandidateState {
    $f = Join-Path (Initialize-RgHome) 'state\scan-candidates.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (ConvertFrom-Json (Read-RgFileShared $f)) } catch { return $null }
}

function New-RgActionResult([string]$Id, [string]$Actor, [string]$Outcome, [string]$Reason = '', $Group = '', $Level = '', $Result = $null) {
    return [pscustomobject][ordered]@{ ok = ($Outcome -eq 'done' -or $Outcome -eq 'dry-run'); id = $Id; actor = $Actor; outcome = $Outcome; reason = $Reason; group = $Group; level = $Level; result = $Result }
}

# Cửa duy nhất. Actor: human (người bấm ở UI/CLI) | agent (agent đề xuất) | policy (engine tự động). Trả { ok; outcome; reason; ... }.
#   outcome: done | dry-run | refused | proposal | needs-approval | invalid
# Tác nhân không phải người chỉ được THI HÀNH khi nhóm ở L3 VÀ action có permission L3 VÀ chính sách không tắt; còn lại chỉ ghi nhận đề xuất.
function Invoke-RgAction {
    param([Parameter(Mandatory)][string]$Id, $Params = @{}, [ValidateSet('human', 'agent', 'policy')][string]$Actor = 'human', [bool]$PinVerified = $false, [switch]$DryRun, [string]$By = '')
    $a = $script:RgActions[$Id]
    if (-not $a) { return (New-RgActionResult $Id $Actor 'invalid' 'action không có trong danh sách cho phép') }
    $bad = Test-RgActionParams $a $Params
    if ($bad) { return (New-RgActionResult $Id $Actor 'invalid' $bad $a.group) }
    $pol = Get-RgPolicy
    $lv = Get-RgGroupLevel $pol $a.group
    $res = { param($o, $r, $x) New-RgActionResult $Id $Actor $o $r $a.group $lv.level $x }
    $log = { param($o, $r) try { Write-RgLog 'action' ([ordered]@{ id = $Id; actor = $Actor; group = $a.group; level = $lv.level; outcome = $o; reason = $r; dry = [bool]$DryRun }) } catch { } }
    if ($lv.level -eq 'L0') { & $log 'refused' 'nhóm đang tắt (L0)'; return (& $res 'refused' 'Nhóm này đang tắt (mức L0).' $null) }
    if ($Actor -ne 'human') {
        if ([string]$pol.mode -eq 'off') { & $log 'refused' 'policy off'; return (& $res 'refused' 'Chính sách tự động đang tắt.' $null) }
        if ($lv.level -ne 'L3' -or $a.permission -ne 'L3') {
            $o = if ($lv.level -eq 'L1') { 'proposal' } else { 'needs-approval' }
            & $log $o 'chưa đủ mức tự chủ'
            return (& $res $o ("Nhóm '$($script:RgAutonomyGroups[$a.group].label)' đang ở mức $($lv.level): trợ lý chỉ " + $(if ($o -eq 'proposal') { 'đề xuất.' } else { 'chuẩn bị, chờ bạn duyệt.' })) $null)
        }
    }
    $actBy = if ($By) { $By } elseif ($Actor -eq 'human') { "ui`:$env:USERNAME" } else { 'policy' }
    try {
        switch ($Id) {
            'clean-cache' {
                $cd = Read-RgCandidateState
                if (-not $cd) { return (& $res 'refused' 'Chưa có danh sách ứng viên; hãy quét trước.' $null) }
                if (Test-RgScanStale ([string]$cd.finishedUtc)) { return (& $res 'refused' 'Dữ liệu quét đã cũ; hãy quét lại.' $null) }
                $c = @($cd.items | Where-Object { $_.key -eq [string]$Params.key }) | Select-Object -First 1
                if (-not $c) { return (& $res 'refused' 'Mục không còn trong danh sách ứng viên.' $null) }
                if ([string]$c.kind -ne 'cache-aged' -or [string]$c.action -ne 'delete') { return (& $res 'refused' 'Chỉ dọn được mục cache đủ tuổi.' $null) }
                if ([bool]$c.young) { return (& $res 'refused' 'Mục chưa đủ tuổi: chỉ người duyệt mới được xoá.' $null) }
                if ([bool]$c.needsAdmin) { return (& $res 'refused' 'Mục cần quyền admin.' $null) }
                if (Test-RgPathProtected ([string]$c.path) $pol) { return (& $res 'refused' 'Mục nằm trong vùng bảo vệ.' $null) }
                $cfg = Get-RgConfig
                $why = Get-RgDeleteBlocker $c $cfg
                if ($why) { return (& $res 'refused' ([string]$why) $null) }
                if ($DryRun) { & $log 'dry-run' ''; return (& $res 'dry-run' 'Sẽ dọn mục này.' ([ordered]@{ sizeBytes = [long]$c.sizeBytes })) }
                $item = New-RgItem -Kind ([string]$c.kind) -Action 'delete' -Level ([int]$c.level) -Path ([string]$c.path) -SizeBytes ([long]$c.sizeBytes) -NewestUtc ([string]$c.newestWriteUtc) `
                    -Reason ([string]$c.reason) -Risk ([string]$c.risk) -AgeDays ([int]$c.ageDays)
                $plan = New-RgPlan -Items @($item)
                [void](Set-RgPlanApproval -PlanId $plan.planId -ItemIds @($plan.items | ForEach-Object { [int]$_.id }) -By $actBy)
                $ap = Invoke-RgApply -PlanId $plan.planId
                $ok = (@($ap.results | Where-Object { $_.outcome -eq 'done' }).Count -gt 0)
                $o = $(if ($ok) { 'done' } else { 'refused' }); & $log $o ([string]@($ap.results)[0].detail)
                return (& $res $o ([string]@($ap.results)[0].detail) ([ordered]@{ freedBytes = [long]$ap.freedBytes; planId = $plan.planId }))
            }
            { $_ -eq 'archive-cluster' -or $_ -eq 'clean-cluster' } {
                $mode = if ($Id -eq 'archive-cluster') { 'compress' } else { 'clean' }
                if ($DryRun) { return (& $res 'dry-run' 'Sẽ xử lý cụm này.' $null) }
                $r = Invoke-RgClusterAction -ClusterId ([string]$Params.clusterId) -Action $mode -By $actBy
                $o = $(if ($r.done -gt 0) { 'done' } else { 'refused' }); & $log $o ''
                return (& $res $o $(if ($r.done -gt 0) { '' } else { 'Không tệp nào được xử lý (xem chi tiết ở kết quả).' }) $r)
            }
            'lower-priority' {
                if (-not (Get-Command Set-RgProcPriority -ErrorAction SilentlyContinue)) { . (Join-Path $script:RgScriptsDir 'rg-proc.ps1') }
                if ($DryRun) { $t = Test-RgProcLowerable ([int]$Params.pid) ([string]$Params.start); return (& $res $(if ($t.ok) { 'dry-run' } else { 'refused' }) ([string]$t.reason) $null) }
                $r = Set-RgProcPriority ([int]$Params.pid) ([string]$Params.start) ([string]$Params.level)
                $o = $(if ($r.ok) { 'done' } else { 'refused' }); & $log $o ([string]$r.error)
                return (& $res $o ([string]$r.error) $r)
            }
            'end-process' {
                if (-not (Get-Command Invoke-RgProcEnd -ErrorAction SilentlyContinue)) { . (Join-Path $script:RgScriptsDir 'rg-proc.ps1') }
                if ($DryRun) { $t = Test-RgProcEndable ([int]$Params.pid) ([string]$Params.start) (New-RgProcContext -FreshSelf); return (& $res $(if ($t.ok) { 'dry-run' } else { 'refused' }) ([string]$t.reason) $null) }
                $r = Invoke-RgProcEnd ([int]$Params.pid) ([string]$Params.start) $PinVerified
                $o = $(if ($r.ok) { 'done' } else { 'refused' }); & $log $o ([string]$r.error)
                return (& $res $o ([string]$r.error) $r)
            }
        }
    } catch {
        & $log 'refused' ([string]$_.Exception.Message)
        return (& $res 'refused' ([string]$_.Exception.Message) $null)
    }
    return (& $res 'invalid' 'action chưa được hỗ trợ' $null)
}

# ---------- E3: trạng thái chống lặp + banner ----------
function Get-RgAutonomyStatePath { return (Join-Path (Initialize-RgHome) 'state\autonomy-state.json') }
function Read-RgAutonomyState {
    $s = [ordered]@{ notified = $false; notifiedUtc = $null; snoozeUntil = $null; lastRunUtc = $null; overSince = $null; message = ''; drives = @(); demotions = @() }
    $p = Get-RgAutonomyStatePath
    if (Test-Path -LiteralPath $p) { try { $j = ConvertFrom-Json (Read-RgFileShared $p); foreach ($pr in $j.PSObject.Properties) { $s[$pr.Name] = $pr.Value } } catch { } }
    return $s
}
function Save-RgAutonomyState($S) { Write-RgFileAtomic (Get-RgAutonomyStatePath) (ConvertTo-Json -InputObject $S -Depth 5 -Compress) }

function Test-RgSnoozed($S) {
    if (-not $S.snoozeUntil) { return $false }
    try { return ([datetime]::Parse([string]$S.snoozeUntil, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime() -gt (Get-Date).ToUniversalTime()) } catch { return $false }
}

# Banner cho trang Tổng quan: chỉ khi đã báo (notified) và chưa hoãn.
function Get-RgAutonomyBanner {
    $s = Read-RgAutonomyState
    if (-not [bool]$s.notified -or (Test-RgSnoozed $s)) { return [pscustomobject]@{ active = $false } }
    return [pscustomobject]@{ active = $true; since = $s.notifiedUtc; message = [string]$s.message; drives = @($s.drives) }
}

function Set-RgAutonomySnooze([int]$Hours = 6) {
    $s = Read-RgAutonomyState
    $s.snoozeUntil = (Get-Date).ToUniversalTime().AddHours([math]::Min(168, [math]::Max(1, $Hours))).ToString('o')
    Save-RgAutonomyState $s
    Write-RgLog 'autonomy-snooze' ([ordered]@{ hours = $Hours })
    return $s
}

# Gọi sau mỗi lượt tự dọn THẬT và (rẻ) mỗi tick khi hết áp lực. Đo lại: vẫn quá mốc -> báo MỘT lần; xuống dưới mốc -> mở khoá để lần vượt sau báo lại.
#   $Stress = Get-RgStressInfo mới đo. $FreedBytes = số vừa giải phóng (chỉ để ghi chú).
function Update-RgAutonomyState($Stress, [long]$FreedBytes = 0, [bool]$Ran = $false) {
    $s = Read-RgAutonomyState
    $over = [bool]($Stress.diskStress -or $Stress.ramStress)
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($Ran) { $s.lastRunUtc = $now }
    if (-not $over) {
        if ([bool]$s.notified -or $s.overSince) { $s.notified = $false; $s.notifiedUtc = $null; $s.overSince = $null; $s.message = ''; $s.drives = @(); $s.snoozeUntil = $null; Save-RgAutonomyState $s; Write-RgLog 'autonomy-clear' @{ } }
        return [pscustomobject]@{ over = $false; notified = $false }
    }
    if (-not $s.overSince) { $s.overSince = $now }
    $newly = $false
    if ($Ran -and -not [bool]$s.notified -and -not (Test-RgSnoozed $s)) {
        $dr = @($Stress.drives | Where-Object { $_.stress } | ForEach-Object { [ordered]@{ drive = $_.drive; freeGB = $_.freeGB; targetFreeGB = $_.targetFreeGB } })
        $msg = if ($Stress.diskStress) { 'Đã tự dọn trong phạm vi cho phép nhưng ổ đĩa vẫn dưới mốc trống.' } else { 'Đã xử lý trong phạm vi cho phép nhưng RAM vẫn dưới mốc.' }
        if ($FreedBytes -gt 0) { $msg += (' Giải phóng được ' + [string][math]::Round($FreedBytes / 1GB, 2) + ' GB.') }
        $s.notified = $true; $s.notifiedUtc = $now; $s.message = $msg; $s.drives = $dr; $newly = $true
        Write-RgLog 'autonomy-banner' ([ordered]@{ drives = $dr; freedBytes = $FreedBytes })
    }
    Save-RgAutonomyState $s
    return [pscustomobject]@{ over = $true; notified = [bool]$s.notified; newlyNotified = $newly }
}

# ---------- E4: nâng/hạ mức theo số liệu ----------
function Get-RgAutonomyCfg($Cfg) {
    $d = [ordered]@{ promoteMinRuns = 5; promoteMinDays = 7; demoteRestoreRate = 0.25; demoteMinArchives = 4; demoteFailures = 3; windowDays = 30 }
    try { if ($Cfg -and $Cfg.PSObject.Properties['autonomy'] -and $Cfg.autonomy) { foreach ($k in @($d.Keys)) { $p = $Cfg.autonomy.PSObject.Properties[$k]; if ($p -and $null -ne $p.Value) { $d[$k] = [double]$p.Value } } } } catch { }
    return [pscustomobject]$d
}

# Bằng chứng theo nhóm từ nhật ký (chỉ đọc). Trả { dryRuns; days; wouldBytes; realRuns; failed; archives; restores; restoreRate }.
function Get-RgGroupEvidence($Cfg, [string]$Group) {
    $ac = Get-RgAutonomyCfg $Cfg
    $g = $script:RgAutonomyGroups[$Group]
    $ev = @(Read-RgAutoRunEvents ([int]$ac.windowDays))
    $dry = 0; $real = 0; $would = 0L; $first = $null; $last = $null
    foreach ($e in $ev) {
        $d = $e.data; if (-not $d) { continue }
        $kb = $null; try { $kb = $d.byKind } catch { }
        $n = 0; $by = 0L
        foreach ($k in @($g.kinds)) { if ($kb -and $kb.PSObject.Properties[$k]) { $n += [int]$kb.$k.items; $by += [long]$kb.$k.bytes } }
        if ($n -le 0) { continue }
        $t = $null; try { $t = [datetime]::Parse([string]$e.ts, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') } catch { }
        if ([string]$d.mode -eq 'dry-run') { $dry++; $would += $by } else { $real++ }
        if ($t) { if (-not $first -or $t -lt $first) { $first = $t }; if (-not $last -or $t -gt $last) { $last = $t } }
    }
    $m = Get-RgEffectMetrics ([int]$ac.windowDays)
    $days = if ($first -and $last) { [int][math]::Floor(($last - $first).TotalDays) } else { 0 }
    $arch = 0; $res = 0; $rate = 0.0
    if ($Group -eq 'personal-compress') { $arch = [int]$m.archives; $res = [int]$m.restores; $rate = [double]$m.restoreRate }
    return [pscustomobject]@{ group = $Group; dryRuns = $dry; realRuns = $real; days = $days; wouldBytes = $would; failed = [int]$m.failed; archives = $arch; restores = $res; restoreRate = $rate }
}

# Đề nghị nâng (người cấp bằng PIN) và danh sách cần hạ. Chỉ đọc.
function Get-RgAutonomyAdvice {
    param($Cfg = $null, $Policy = $null)
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    $ac = Get-RgAutonomyCfg $Cfg
    $promote = @(); $demote = @()
    foreach ($gid in $script:RgAutonomyGroups.Keys) {
        $g = $script:RgAutonomyGroups[$gid]; $lv = (Get-RgGroupLevel $Policy $gid).level
        $ev = Get-RgGroupEvidence $Cfg $gid
        $rank = Get-RgLevelRank $lv
        if ($gid -eq 'dev-cache' -and $rank -lt 3 -and $rank -ge 1 -and $ev.dryRuns -ge [int]$ac.promoteMinRuns -and $ev.days -ge [int]$ac.promoteMinDays -and $ev.failed -lt [int]$ac.demoteFailures) {
            $promote += [pscustomobject]@{ group = $gid; label = $g.label; from = $lv; to = 'L3'; needsPin = $true; evidence = $ev
                reason = ("{0} lượt chạy thử trong {1} ngày, đều không lỗi; nếu bật, mỗi lượt dọn khoảng {2:n1} GB." -f $ev.dryRuns, $ev.days, ($ev.wouldBytes / 1GB / [math]::Max(1, $ev.dryRuns))) }
        }
        if ($gid -eq 'personal-compress' -and $rank -ge 1 -and $rank -lt 2 -and $ev.archives -ge [int]$ac.promoteMinRuns -and $ev.restoreRate -lt 0.05) {
            $promote += [pscustomobject]@{ group = $gid; label = $g.label; from = $lv; to = 'L2'; needsPin = $false; evidence = $ev
                reason = ("Bạn đã nén {0} cụm trong {1} ngày và gần như không phải khôi phục; có thể để trợ lý chuẩn bị sẵn." -f $ev.archives, [int]$ac.windowDays) }
        }
        if ($gid -eq 'personal-compress' -and $rank -ge 2 -and $ev.archives -ge [int]$ac.demoteMinArchives -and $ev.restoreRate -ge [double]$ac.demoteRestoreRate) {
            $demote += [pscustomobject]@{ group = $gid; label = $g.label; from = $lv; to = 'L1'; evidence = $ev; reason = ("Bạn khôi phục {0}/{1} bản nén ({2:p0}); hạ về mức đề xuất." -f $ev.restores, $ev.archives, $ev.restoreRate) }
        }
        if ($gid -eq 'dev-cache' -and $rank -ge 3 -and $ev.failed -ge [int]$ac.demoteFailures) {
            $demote += [pscustomobject]@{ group = $gid; label = $g.label; from = $lv; to = 'L2'; evidence = $ev; reason = ("{0} lần dọn lỗi gần đây; hạ về chờ duyệt cho tới khi kiểm tra." -f $ev.failed) }
        }
    }
    return [pscustomobject]@{ promote = @($promote); demote = @($demote) }
}

# Tự hạ mức khi số liệu xấu (hạ luôn được phép, không cần PIN). Ghi nhật ký + nhớ lại trong state. Trả danh sách đã hạ.
function Invoke-RgAutonomyDemote {
    param($Cfg = $null)
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    $pol = Get-RgPolicy
    $adv = Get-RgAutonomyAdvice $Cfg $pol
    if (@($adv.demote).Count -eq 0) { return @() }
    $ex = Get-RgAutonomyExplicit $pol
    foreach ($d in @($adv.demote)) { $ex[[string]$d.group] = [string]$d.to }
    $pol.autonomy = $ex
    [void](Save-RgPolicy $pol)
    $s = Read-RgAutonomyState
    $s.demotions = @(@($s.demotions) + @($adv.demote | ForEach-Object { [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); group = $_.group; from = $_.from; to = $_.to; reason = $_.reason } }) | Select-Object -Last 20)
    Save-RgAutonomyState $s
    foreach ($d in @($adv.demote)) { Write-RgLog 'autonomy-demote' ([ordered]@{ group = $d.group; from = $d.from; to = $d.to; reason = $d.reason }) }
    return @($adv.demote)
}

# Đặt mức một nhóm. Nâng lên L3 cần PinVerified. Trả { ok; code; error; policy }.
function Set-RgGroupLevel([string]$Group, [string]$Level, [bool]$PinVerified = $false) {
    $g = $script:RgAutonomyGroups[$Group]
    if (-not $g) { return [pscustomobject]@{ ok = $false; code = 'bad-group'; error = 'Nhóm không hợp lệ.' } }
    $Level = $Level.Trim().ToUpperInvariant()
    if ($script:RgLevels -notcontains $Level) { return [pscustomobject]@{ ok = $false; code = 'bad-level'; error = 'Mức phải là L0, L1, L2 hoặc L3.' } }
    if ((Get-RgLevelRank $Level) -gt (Get-RgLevelRank $g.cap)) { return [pscustomobject]@{ ok = $false; code = 'over-cap'; error = "Nhóm này tối đa là $($g.cap): luôn chờ bạn duyệt." } }
    $old = Get-RgPolicy
    $ex = Get-RgAutonomyExplicit $old; $ex[$Group] = $Level
    $new = Get-RgPolicy; $new.autonomy = $ex
    if ((Test-RgAutonomyNeedsPin $old $new) -and -not $PinVerified) { return [pscustomobject]@{ ok = $false; code = 'pin-required'; error = 'Nâng lên mức tự động cần PIN.' } }
    $saved = Save-RgPolicy $new
    Write-RgLog 'autonomy-change' ([ordered]@{ group = $Group; from = (Get-RgGroupLevel $old $Group).level; to = $Level })
    return [pscustomobject]@{ ok = $true; code = ''; error = ''; policy = $saved }
}

# ---------- E4: dừng khẩn cấp ----------
# Tắt chính sách (mode = off), huỷ mọi job nền của Resource Guard đang chạy (chỉ tiến trình mà dòng lệnh khớp tên job của chính mình, xác minh trước khi dừng),
# xoá banner, ghi nhật ký. Không cần PIN (dừng luôn được phép). Bật lại chính sách thì cần PIN như thường lệ.
$script:RgPanicJobs = @('auto.progress.json', 'cleanup.progress.json', 'agent.progress.json', 'scan-inventory.progress.json', 'scan-candidates.progress.json', 'scan-breakdown.progress.json')
$script:RgPanicCmdRegex = 'rg-(auto|scan|agent|cleanup|assistant-act|restore|elevate)\.ps1'
function Invoke-RgPanic {
    param([string]$By = 'ui')
    $out = [ordered]@{ ok = $true; by = $By; modeBefore = ''; stopped = @(); failed = @(); ts = (Get-Date).ToUniversalTime().ToString('o') }
    try {
        $pol = Get-RgPolicy
        $out.modeBefore = [string]$pol.mode
        if ([string]$pol.mode -ne 'off') { $pol.mode = 'off'; [void](Save-RgPolicy $pol) }
    } catch { $out.ok = $false; $out.failed += [pscustomobject]@{ what = 'policy'; error = [string]$_.Exception.Message } }
    foreach ($f in $script:RgPanicJobs) {
        try {
            $j = Get-RgJobState $f
            if (-not $j -or $j.status -ne 'running' -or -not $j.pid) { continue }
            $jp = [int]$j.pid
            if ($jp -eq $PID) { continue }
            $c = Get-CimInstance Win32_Process -Filter "ProcessId=$jp" -ErrorAction SilentlyContinue
            if (-not $c -or -not ([string]$c.CommandLine -match $script:RgPanicCmdRegex)) { continue }
            $k = Stop-RgProcessVerified -ProcId $jp -Start (ConvertTo-RgStamp $c.CreationDate) -Name (([string]$c.Name -replace '\.exe$', '').ToLowerInvariant()) -GraceSec 3
            if ($k.ok) {
                $out.stopped += $f
                Write-RgJobState $f ([ordered]@{ pid = $jp; status = 'error'; message = 'dừng khẩn cấp'; startedUtc = [string]$j.startedUtc; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
            } else { $out.failed += [pscustomobject]@{ what = $f; error = [string]$k.reason } }
        } catch { $out.failed += [pscustomobject]@{ what = $f; error = [string]$_.Exception.Message } }
    }
    try {
        $s = Read-RgAutonomyState
        $s.notified = $false; $s.notifiedUtc = $null; $s.overSince = $null; $s.message = ''; $s.drives = @()
        Save-RgAutonomyState $s
    } catch { }
    try { Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\panic-last.json') (ConvertTo-Json -InputObject $out -Depth 4 -Compress) } catch { }
    Write-RgLog 'panic' ([ordered]@{ by = $By; modeBefore = $out.modeBefore; stopped = @($out.stopped).Count; failed = @($out.failed).Count })
    return [pscustomobject]$out
}
