# rg-proc.ps1 - HẠ ƯU TIÊN tiến trình (đảo ngược được) và KẾT THÚC tiến trình từ app (B1). Dot-source sau rg-common.ps1 và rg-policy.ps1.
# File này không tự gọi API dừng tiến trình của Windows: việc kết thúc luôn đi qua Stop-RgProcessVerified (rg-common.ps1), cửa duy nhất
# (kiểm lại PID + start time + tên, đóng êm trước, buộc sau, xác minh đã thoát). Hạ ưu tiên chỉ đổi PriorityClass Normal <-> BelowNormal.
# An toàn: mọi kiểm tra thuộc về MỘT hàm quyết định (Get-RgProcLowerVerdict / Get-RgProcEndVerdict) dùng chung cho danh sách (canLower, canEnd, whyNot)
# và cho lúc thực thi, nên nút trên UI và việc server thực sự làm luôn khớp. Lúc thực thi còn kiểm lại bằng dữ liệu sống.

# Tên tiến trình của Windows/giao diện: không bao giờ đụng tới dù ở phiên người dùng.
$script:RgProcCriticalNames = @('system', 'idle', 'registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'lsm', 'svchost',
    'dwm', 'fontdrvhost', 'sihost', 'ctfmon', 'taskhostw', 'audiodg', 'memcompression', 'explorer', 'searchhost', 'startmenuexperiencehost',
    'shellexperiencehost', 'textinputhost', 'runtimebroker', 'securityhealthservice', 'msmpeng', 'wudfhost', 'spoolsv', 'conhost', 'winlogon')
# Dòng lệnh của chính Resource Guard (server, job quét, watcher, agent...).
$script:RgProcSelfCmdRegex = 'rg-(server|scan|watcher|agent|auto|cleanup|elevated-clean|common|policy|proc|insight)\.ps1|resource-manager\.ps1'

function Get-RgProcPriorityPath { return (Join-Path (Initialize-RgHome) 'state\proc-priority.json') }

# So start time (chuỗi stamp yyyyMMddTHHmmssZ) với Process.StartTime; cho lệch <= 2 giây do làm tròn WMI/kernel.
function Test-RgProcStartMatch($Proc, [string]$Stamp) {
    try {
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Stamp, "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt)) { return $false }
        return ([math]::Abs(($Proc.StartTime.ToUniversalTime() - $dt).TotalSeconds) -le 2)
    } catch { return $false }
}

function Test-RgProcAliveStamp([int]$ProcId, [string]$Stamp) {
    $p = $null
    try { $p = [Diagnostics.Process]::GetProcessById($ProcId) } catch { return $false }
    try { return (Test-RgProcStartMatch $p $Stamp) } finally { $p.Dispose() }
}

# Danh sách tiến trình đang bị Resource Guard hạ. Mục có PID không còn sống (hoặc PID bị dùng lại) bị dọn khi đọc.
function Read-RgProcPriority {
    $f = Get-RgProcPriorityPath
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $all = @()
    try { $all = @(ConvertFrom-Json (Read-RgFileShared $f) | ForEach-Object { $_ }) } catch { return @() }
    $keep = @($all | Where-Object { $_ -and $_.pid -and (Test-RgProcAliveStamp ([int]$_.pid) ([string]$_.start)) })
    if ($keep.Count -ne $all.Count) { Write-RgFileAtomic $f (ConvertTo-Json -InputObject @($keep) -Depth 4) }
    return $keep
}

function Save-RgProcPriority($Entries) { Write-RgFileAtomic (Get-RgProcPriorityPath) (ConvertTo-Json -InputObject @($Entries) -Depth 4) }

# PID của chính tiến trình đang chạy mã này (server hoặc tiến trình test). Job nền của Resource Guard (rg-scan, rg-auto, rg-agent...)
# được nhận ra qua $script:RgProcSelfCmdRegex trong Get-RgProcLowerVerdict, nên không cần duyệt cây tiến trình.
function Get-RgSelfPids([switch]$Fresh) {
    return @{ ([int]$PID) = $true }
}

# Bối cảnh dùng chung cho nhiều dòng: dựng MỘT lần mỗi yêu cầu.
function New-RgProcContext($Cfg = $null, $Policy = $null, [switch]$FreshSelf, $Table = $null) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    $ledger = @{}; $ledgerEntries = @{}
    foreach ($e in @(Read-RgLedger)) { if ($e.pid) { $ledger[[int]$e.pid] = $true; $ledgerEntries[[int]$e.pid] = $e } }
    $lowered = @{}; foreach ($e in @(Read-RgProcPriority)) { $lowered["$([int]$e.pid)|$([string]$e.start)"] = $e }
    # ledger tầng quan sát (C3): hậu duệ build/test/dev của phiên agent đang giữ lease. Không có lease nào thì không tốn thêm gì.
    $observed = @{}
    try { foreach ($o in @(Get-RgObservedLedger -Table $Table -Cfg $Cfg)) { if (-not $ledger.ContainsKey([int]$o.pid)) { $observed[[int]$o.pid] = $o } } } catch { }
    return [pscustomobject]@{
        cfg = $Cfg; policy = $Policy; ledger = $ledger; ledgerEntries = $ledgerEntries; observed = $observed; lowered = $lowered
        self = (Get-RgSelfPids -Fresh:$FreshSelf); session = [int][Diagnostics.Process]::GetCurrentProcess().SessionId
    }
}

# Quyết định THUẦN (không đụng hệ thống): '' nếu được hạ ưu tiên, ngược lại lý do tiếng Việt.
#   $Session = Session ID của tiến trình ($null nếu không đọc được).
function Get-RgProcLowerVerdict([int]$ProcId, [string]$Name, [string]$Group, [string]$Cmd, $Session, $Ctx) {
    $n = ([string]$Name -replace '\.exe$', '').ToLowerInvariant()
    if ($ProcId -le 4) { return 'Tiến trình hệ thống: không đụng tới.' }
    if ($Ctx.self.ContainsKey($ProcId) -or ($Cmd -and $Cmd -match $script:RgProcSelfCmdRegex)) { return 'Đây là tiến trình của chính Resource Guard.' }
    if ($Group -eq 'agent' -or $Ctx.ledger.ContainsKey($ProcId)) { return 'Tiến trình của trợ lý AI: Resource Guard không đụng tới.' }
    if ($Group -eq 'infra') { return 'Hạ tầng (Docker, SQL Server, WSL...): không hạ ưu tiên để tránh làm treo dịch vụ.' }
    if ($script:RgProcCriticalNames -contains $n) { return 'Tiến trình hệ thống hoặc giao diện Windows: không đụng tới.' }
    if (Test-RgProcessProtected $n $Ctx.policy) { return 'Bạn đã đặt tiến trình này vào vùng bảo vệ.' }
    if ($null -eq $Session) { return 'Không đọc được phiên chạy của tiến trình này.' }
    if ([int]$Session -eq 0) { return 'Tiến trình dịch vụ hệ thống (phiên 0): không đụng tới.' }
    if ([int]$Session -ne [int]$Ctx.session) { return 'Tiến trình thuộc phiên đăng nhập khác.' }
    return ''
}

# Kiểm bằng dữ liệu SỐNG ngay trước khi làm. Trả { ok; reason; name; current; process }.
# PID + start time + tên khớp; verdict thuần ở trên; mức ưu tiên hiện tại phải là Normal.
function Test-RgProcLowerable([int]$ProcId, [string]$Start, $Ctx = $null) {
    $res = [ordered]@{ ok = $false; reason = ''; name = ''; current = '' }
    try {
        if ($null -eq $Ctx) { $Ctx = New-RgProcContext -FreshSelf }
        if ($ProcId -le 4) { $res.reason = 'Tiến trình hệ thống: không đụng tới.'; return [pscustomobject]$res }
        $c = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
        if (-not $c) { $res.reason = 'Tiến trình không còn chạy.'; return [pscustomobject]$res }
        if ((ConvertTo-RgStamp $c.CreationDate) -ne $Start) { $res.reason = 'Tiến trình đã thay đổi (PID được dùng lại). Hãy tải lại danh sách.'; return [pscustomobject]$res }
        $name = ([string]$c.Name -replace '\.exe$', '').ToLowerInvariant(); $res.name = $name
        $cmd = [string]$c.CommandLine
        $grp = Get-RgGroup $name $cmd $Ctx.cfg
        $why = Get-RgProcLowerVerdict $ProcId $name $grp $cmd $c.SessionId $Ctx
        if ($why) { $res.reason = $why; return [pscustomobject]$res }
        if ($Ctx.lowered.ContainsKey("$ProcId|$Start")) { $res.reason = 'Đã được hạ ưu tiên rồi.'; return [pscustomobject]$res }
        $p = $null
        try { $p = [Diagnostics.Process]::GetProcessById($ProcId) } catch { $res.reason = 'Tiến trình không còn chạy.'; return [pscustomobject]$res }
        try {
            if (-not (Test-RgProcStartMatch $p $Start)) { $res.reason = 'Tiến trình đã thay đổi (PID được dùng lại). Hãy tải lại danh sách.'; return [pscustomobject]$res }
            $cur = $null
            try { $cur = [string]$p.PriorityClass } catch { $res.reason = 'Windows không cho đọc mức ưu tiên của tiến trình này (cần quyền cao hơn).'; return [pscustomobject]$res }
            $res.current = $cur
            if ($cur -ne 'Normal') { $res.reason = "Tiến trình đang ở mức ưu tiên '$cur' (không phải Bình thường): không đụng tới."; return [pscustomobject]$res }
        } finally { $p.Dispose() }
        $res.ok = $true
    } catch { $res.reason = 'Không kiểm tra được tiến trình: ' + [string]$_.Exception.Message }
    return [pscustomobject]$res
}

# Hạ (below) hoặc trả về bình thường (normal). KHÔNG ném lỗi: trả { ok; pid; name; level; from; to; error }.
function Set-RgProcPriority([int]$ProcId, [string]$Start, [string]$Level) {
    $r = [ordered]@{ ok = $false; pid = $ProcId; name = ''; level = $Level; from = ''; to = ''; error = '' }
    try {
        if (@('below', 'normal') -notcontains $Level) { $r.error = "Mức '$Level' không hợp lệ (chỉ 'below' hoặc 'normal')."; return [pscustomobject]$r }
        if ($Start -notmatch '^\d{8}T\d{6}Z$') { $r.error = 'Thiếu hoặc sai thời điểm khởi động của tiến trình.'; return [pscustomobject]$r }
        $ctx = New-RgProcContext -FreshSelf
        $entries = @(Read-RgProcPriority)
        if ($Level -eq 'below') {
            $t = Test-RgProcLowerable $ProcId $Start $ctx
            $r.name = [string]$t.name
            if (-not $t.ok) { $r.error = [string]$t.reason; return [pscustomobject]$r }
            $p = [Diagnostics.Process]::GetProcessById($ProcId)
            try {
                if (-not (Test-RgProcStartMatch $p $Start)) { $r.error = 'Tiến trình đã thay đổi (PID được dùng lại). Hãy tải lại danh sách.'; return [pscustomobject]$r }
                $r.from = [string]$p.PriorityClass
                try { $p.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { $r.error = 'Windows không cho đổi mức ưu tiên của tiến trình này (cần quyền cao hơn).'; return [pscustomobject]$r }
                $p.Refresh(); $r.to = [string]$p.PriorityClass
            } finally { $p.Dispose() }
            $entries += [pscustomobject]@{ pid = $ProcId; start = $Start; name = $r.name; from = $r.from; loweredUtc = (Get-Date).ToUniversalTime().ToString('o') }
            Save-RgProcPriority $entries
        } else {
            $mine = @($entries | Where-Object { [int]$_.pid -eq $ProcId -and [string]$_.start -eq $Start }) | Select-Object -First 1
            if (-not $mine) {
                $r.error = $(if (Test-RgProcAliveStamp $ProcId $Start) { 'Resource Guard chưa hạ ưu tiên tiến trình này nên không đổi lại.' } else { 'Tiến trình đã kết thúc.' })
                return [pscustomobject]$r
            }
            $r.name = [string]$mine.name
            $p = [Diagnostics.Process]::GetProcessById($ProcId)
            try {
                if (-not (Test-RgProcStartMatch $p $Start)) { $r.error = 'Tiến trình đã thay đổi (PID được dùng lại).'; return [pscustomobject]$r }
                $r.from = [string]$p.PriorityClass
                try { $p.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal } catch { $r.error = 'Windows không cho đổi mức ưu tiên của tiến trình này.'; return [pscustomobject]$r }
                $p.Refresh(); $r.to = [string]$p.PriorityClass
            } finally { $p.Dispose() }
            Save-RgProcPriority @($entries | Where-Object { -not ([int]$_.pid -eq $ProcId -and [string]$_.start -eq $Start) })
        }
        Write-RgLog 'proc-priority' ([ordered]@{ pid = $ProcId; name = $r.name; from = $r.from; to = $r.to })
        $r.ok = $true
    } catch { $r.error = 'Không đổi được mức ưu tiên: ' + [string]$_.Exception.Message }
    return [pscustomobject]$r
}

# ===================== Kết thúc tiến trình từ app (B1, docs §8) =====================
# Allowlist THEO LỚP (vai trò suy ra từ danh tính tiến trình), không chỉ denylist: chỉ lớp trong kill.allowedRoles mới được kết thúc.
# Không bao giờ đủ điều kiện: hệ thống, bảo mật, dịch vụ/phiên khác, hạ tầng (Docker/SQL/WSL), chính Resource Guard, vùng người dùng đã bảo vệ.
# Tiến trình do trợ lý AI đăng ký (ledger) được phép kết thúc kể cả khi lớp không nằm trong allowlist, nhưng nếu chủ (agent) còn sống
# thì tiến trình đang giữ lease của agent => cần PIN. Chủ đã chết (mồ côi) => một cú bấm.
$script:RgDefaultEndRoles = @('build', 'test', 'devserver', 'packagemgr', 'compiler', 'langserver', 'runtime-app')

function Get-RgEndRoles($Cfg) {
    try { if ($Cfg -and $Cfg.PSObject.Properties['kill'] -and $Cfg.kill -and $Cfg.kill.PSObject.Properties['allowedRoles'] -and $Cfg.kill.allowedRoles) { return @($Cfg.kill.allowedRoles | ForEach-Object { [string]$_ }) } } catch { }
    return $script:RgDefaultEndRoles
}

# Quyết định THUẦN. Trả { ok; reason; needsPin; ledger; role }. $Role = vai trò từ Get-RgProcIdentity ('' nếu chưa rõ).
function Get-RgProcEndVerdict([int]$ProcId, [string]$Name, [string]$Group, [string]$Cmd, $Session, [string]$Role, $Ctx, [string]$Start = '') {
    $n = ([string]$Name -replace '\.exe$', '').ToLowerInvariant()
    $res = [ordered]@{ ok = $false; reason = ''; needsPin = $false; ledger = $false; observed = $false; role = $Role }
    $deny = { param($m) $res.reason = $m; return [pscustomobject]$res }
    if ($ProcId -le 4) { return (& $deny 'Tiến trình hệ thống: không đụng tới.') }
    if ($Ctx.self.ContainsKey($ProcId) -or ($Cmd -and $Cmd -match $script:RgProcSelfCmdRegex)) { return (& $deny 'Đây là tiến trình của chính Resource Guard.') }
    if ($script:RgProcCriticalNames -contains $n) { return (& $deny 'Tiến trình hệ thống hoặc giao diện Windows: không đụng tới.') }
    if (@('system', 'security') -contains $Role) { return (& $deny 'Do Windows quản lý: không kết thúc từ đây.') }
    if ($Group -eq 'infra') { return (& $deny 'Hạ tầng (Docker, SQL Server, WSL...): dừng từ chính dịch vụ đó, không kết thúc từ đây để tránh hỏng dữ liệu.') }
    $entry = $null
    if ($Ctx.ledgerEntries -and $Ctx.ledgerEntries.ContainsKey($ProcId)) {
        $e = $Ctx.ledgerEntries[$ProcId]
        if (-not $Start -or [string]$e.start -eq $Start) { $entry = $e }
    }
    if ($Group -eq 'agent' -and -not $entry) { return (& $deny 'Tiến trình của trợ lý AI: hãy kết thúc phiên từ chính ứng dụng đó.') }
    if (Test-RgProcessProtected $n $Ctx.policy) { return (& $deny 'Bạn đã đặt tiến trình này vào vùng bảo vệ.') }
    if ($null -eq $Session) { return (& $deny 'Không đọc được phiên chạy của tiến trình này.') }
    if ([int]$Session -eq 0) { return (& $deny 'Tiến trình dịch vụ hệ thống (phiên 0): không đụng tới.') }
    if ([int]$Session -ne [int]$Ctx.session) { return (& $deny 'Tiến trình thuộc phiên đăng nhập khác.') }
    if ($entry) {
        $res.ledger = $true
        $ownerAlive = $false
        if ($entry.ownerStart) { $ownerAlive = [bool](Test-RgProcessIdentity ([int]$entry.ownerPid) ([string]$entry.ownerStart) '') }
        $res.needsPin = $ownerAlive   # agent còn sống = đang giữ lease
        $res.ok = $true
        return [pscustomobject]$res
    }
    if (-not $Role) { return (& $deny 'Chưa nhận diện được loại tiến trình này nên không cho kết thúc từ app. Hãy đóng từ chính ứng dụng.') }
    if ((Get-RgEndRoles $Ctx.cfg) -notcontains $Role) { return (& $deny "Loại '$Role' không nằm trong danh sách được kết thúc từ app. Hãy đóng từ chính ứng dụng, sau khi lưu việc đang làm.") }
    $res.ok = $true
    # quan sát được là con cháu của phiên agent ĐANG SỐNG (giữ lease): giống tiến trình có ledger, cần PIN. Lớp vẫn phải nằm trong allowlist ở trên.
    if ($Ctx.PSObject.Properties['observed'] -and $Ctx.observed -and $Ctx.observed.ContainsKey($ProcId) -and (-not $Start -or [string]$Ctx.observed[$ProcId].start -eq $Start)) {
        $res.needsPin = $true; $res.observed = $true
    }
    return [pscustomobject]$res
}

# Kiểm bằng dữ liệu SỐNG ngay trước khi làm: PID + start time + tên khớp, rồi verdict thuần. Trả { ok; reason; needsPin; ledger; role; name; ramMB }.
function Test-RgProcEndable([int]$ProcId, [string]$Start, $Ctx = $null) {
    $res = [ordered]@{ ok = $false; reason = ''; needsPin = $false; ledger = $false; role = ''; name = ''; ramMB = 0 }
    try {
        if ($null -eq $Ctx) { $Ctx = New-RgProcContext -FreshSelf }
        if ($ProcId -le 4) { $res.reason = 'Tiến trình hệ thống: không đụng tới.'; return [pscustomobject]$res }
        $c = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
        if (-not $c) { $res.reason = 'Tiến trình không còn chạy.'; return [pscustomobject]$res }
        if ((ConvertTo-RgStamp $c.CreationDate) -ne $Start) { $res.reason = 'Tiến trình đã thay đổi (PID được dùng lại). Hãy tải lại danh sách.'; return [pscustomobject]$res }
        $name = ([string]$c.Name -replace '\.exe$', '').ToLowerInvariant(); $res.name = $name
        $res.ramMB = [math]::Round([double]$c.WorkingSetSize / 1MB, 0)
        $cmd = [string]$c.CommandLine
        $grp = Get-RgGroup $name $cmd $Ctx.cfg
        $role = ''
        try {   # vai trò cần chuỗi cha: dựng bảng tiến trình một lần (CIM), chỉ khi bấm kết thúc nên chấp nhận chi phí
            $tbl = @(Get-RgProcessTable); $by = @{}; foreach ($t in $tbl) { $by[[int]$t.Pid] = $t }
            $row = $by[$ProcId]
            if ($row) { $role = [string](Get-RgProcIdentity $row $by $Ctx.cfg (Get-RgServiceMap) @(Get-RgWorkspaceRoots $Ctx.cfg.cleanup)).role }
        } catch { }
        $v = Get-RgProcEndVerdict $ProcId $name $grp $cmd $c.SessionId $role $Ctx $Start
        $res.ok = $v.ok; $res.reason = $v.reason; $res.needsPin = $v.needsPin; $res.ledger = $v.ledger; $res.role = $v.role
    } catch { $res.reason = 'Không kiểm tra được tiến trình: ' + [string]$_.Exception.Message }
    return [pscustomobject]$res
}

# Kết thúc MỘT tiến trình (cùng cây con thuộc nhóm cho phép). KHÔNG ném lỗi: trả { ok; code; pid; name; method; tree; skipped; freedMB; error }.
# $PinVerified: server đã xác minh PIN (chỉ cần khi tiến trình đang giữ lease của agent). Ghi journal trước/sau và log 'proc-end'.
function Invoke-RgProcEnd([int]$ProcId, [string]$Start, [bool]$PinVerified = $false) {
    $r = [ordered]@{ ok = $false; code = ''; pid = $ProcId; name = ''; method = 'none'; tree = @(); skipped = @(); freedMB = 0; error = '' }
    try {
        if ($Start -notmatch '^\d{8}T\d{6}Z$') { $r.error = 'Thiếu hoặc sai thời điểm khởi động của tiến trình.'; $r.code = 'bad-start'; return [pscustomobject]$r }
        $ctx = New-RgProcContext -FreshSelf
        $t = Test-RgProcEndable $ProcId $Start $ctx
        $r.name = [string]$t.name
        if (-not $t.ok) { $r.error = [string]$t.reason; $r.code = 'not-eligible'; return [pscustomobject]$r }
        if ($t.needsPin -and -not $PinVerified) { $r.error = 'Tiến trình đang do trợ lý AI giữ nên cần PIN.'; $r.code = 'pin-required'; return [pscustomobject]$r }
        $jid = $null
        try { $jid = Write-RgJournalIntent -Action 'kill' -Kind 'process' -Target "pid $ProcId $($t.name)" -Extra ([ordered]@{ via = 'ui'; role = $t.role; ledger = $t.ledger; recovery = 'none' }) }
        catch { $r.error = 'Không ghi được nhật ký nên chưa kết thúc gì: ' + $_.Exception.Message; $r.code = 'journal'; return [pscustomobject]$r }
        $k = Stop-RgProcessVerified -ProcId $ProcId -Start $Start -Name ([string]$t.name) -Cfg $ctx.cfg
        $r.method = [string]$k.method; $r.tree = @($k.tree); $r.skipped = @($k.skipped)
        if ($k.ok) {
            $r.ok = $true; $r.freedMB = [double]$t.ramMB
            Close-RgJournal $jid 'done' "ended ($($k.method)); verified exited"
        } else {
            $r.error = [string]$k.reason; $r.code = 'not-exited'
            Close-RgJournal $jid 'failed' ([string]$k.reason)
        }
        Write-RgLog 'proc-end' ([ordered]@{ pid = $ProcId; name = $t.name; role = $t.role; ledger = $t.ledger; ok = $r.ok; method = $r.method; children = [math]::Max(0, @($k.tree).Count - 1) })
    } catch { $r.error = 'Không kết thúc được: ' + [string]$_.Exception.Message; $r.code = 'error' }
    return [pscustomobject]$r
}

# ===================== Danh tính tiến trình (P2 plan-ux-clarity) =====================
# Trả lời "đây là gì, của ai, để làm gì" CHỈ từ dữ liệu có sẵn trong Get-RgProcessTable (Name, Cmd, ParentPid, Start) + tên dịch vụ cho svchost.
# Không đọc bộ nhớ tiến trình khác, không cần admin. Bảng luật nằm ở config.default.json: identity.rules / identity.launchers.

# Che giá trị nhạy cảm trong dòng lệnh trước khi đưa ra API/UI.
function Hide-RgCmdSecret([string]$Cmd) {
    if (-not $Cmd) { return '' }
    $s = $Cmd
    $s = [regex]::Replace($s, '(?i)(--?(?:password|passwd|pwd|token|secret|api-?key|access-?token|auth)(?:=|\s+))("[^"]*"|''[^'']*''|\S+)', '$1***')
    $s = [regex]::Replace($s, '(?i)((?:apikey|api_key|pwd|password|passwd|token|secret)=)[^&\s;"'']+', '$1***')
    $s = [regex]::Replace($s, '(?<=\s)(-p)\s+("[^"]*"|\S+)', '$1 ***')
    return $s
}

$script:RgSvcCache = $null; $script:RgSvcAt = [datetime]::MinValue
# PID -> danh sách tên hiển thị dịch vụ đang chạy. MỘT lần gọi CIM, cache 60 giây.
function Get-RgServiceMap {
    if ($script:RgSvcCache -and ((Get-Date) - $script:RgSvcAt).TotalSeconds -lt 60) { return $script:RgSvcCache }
    $map = @{}
    try {
        foreach ($s in (Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction Stop)) {
            $sp = [int]$s.ProcessId
            if ($sp -le 0) { continue }
            if (-not $map.ContainsKey($sp)) { $map[$sp] = New-Object System.Collections.ArrayList }
            [void]$map[$sp].Add([string]$s.DisplayName)
        }
    } catch { }
    $script:RgSvcCache = $map; $script:RgSvcAt = Get-Date
    return $map
}

$script:RgIdDefault = $null
# identity.* của cấu hình; config.json cũ của người dùng có thể chưa có khoá này -> rơi về config.default.json.
function Get-RgIdentityConfig($Cfg) {
    if ($Cfg -and $Cfg.PSObject.Properties['identity'] -and $Cfg.identity -and $Cfg.identity.rules) { return $Cfg.identity }
    if (-not $script:RgIdDefault) {
        $p = Join-Path $script:RgScriptsDir '..\config.default.json'
        $script:RgIdDefault = (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).identity
    }
    return $script:RgIdDefault
}

$script:RgIdRegexCache = @{}
$script:RgIdCache = @{}
$script:RgIdRuleByName = @{}; $script:RgIdRuleAt = [datetime]::MinValue
# Regex dựng sẵn theo mẫu: [regex]::Match tĩnh chỉ cache 15 mẫu, bảng luật có hơn 30 nên sẽ dựng lại liên tục (chậm gấp nhiều lần).
function Get-RgIdRegex([string]$Pattern) {
    $r = $script:RgIdRegexCache[$Pattern]
    if ($null -eq $r) { $r = New-Object Text.RegularExpressions.Regex($Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase); $script:RgIdRegexCache[$Pattern] = $r }
    return $r
}

function Test-RgIdName([string]$Name, [string]$Spec) {
    if (-not $Spec) { return $true }
    foreach ($p in ($Spec -split '\|')) { if ($Name -like $p.Trim()) { return $true } }
    return $false
}

# Đường dẫn tuyệt đối đầu tiên trong dòng lệnh nằm dưới một workspace root -> { name; path } (thư mục con cấp 1 dưới root).
function Find-RgProjectInCmd([string]$Cmd, [string[]]$Roots) {
    if (-not $Cmd -or -not $Roots) { return $null }
    foreach ($m in [regex]::Matches($Cmd, '[A-Za-z]:[\\/][^"''<>|*?\r\n]*')) {
        $path = $m.Value.Replace('/', '\')
        foreach ($r in $Roots) {
            if (-not $r) { continue }
            $rt = ($r.TrimEnd('\')) + '\'
            if (-not $path.StartsWith($rt, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rest = $path.Substring($rt.Length)
            $parts = @($rest -split '\\')
            $seg = [string]$parts[0]
            if ($parts.Count -le 1) { $seg = ($seg -split '\s+')[0] }   # đoạn cuối chưa có dấu \ phía sau: phần sau khoảng trắng là tham số
            $seg = $seg.Trim()
            if ($seg) { return [pscustomobject]@{ name = $seg; path = ($rt + $seg) } }
        }
    }
    return $null
}

function Get-RgIdentityCloseHint([string]$Role, $Owner, [string]$Name) {
    switch ($Role) {
        { @('system', 'security') -contains $_ } { return 'Do Windows quản lý; không nên đóng' }
        'infra' { return 'Dừng từ chính dịch vụ đó (Docker, WSL, SQL Server) khi không cần' }
        'browser' { return 'Đóng các tab hoặc cửa sổ trình duyệt không dùng' }
        'editor' { return 'Đóng cửa sổ trình soạn thảo khi không làm việc' }
        'agent' { return 'Kết thúc phiên trợ lý AI từ chính ứng dụng đó' }
        default {
            if ($Owner) { return ('Tự tắt trong {0} (cửa sổ đã chạy nó)' -f $Owner.label) }
            return 'Đóng ứng dụng đã mở nó khi không dùng'
        }
    }
}

# Suy ra danh tính một tiến trình. $Row: { Pid; ParentPid; Name; Start; Cmd; Group }, $ByPid: hashtable PID(int) -> row,
# $Cfg: cấu hình (identity.rules/launchers), $Services: hashtable PID -> mảng tên dịch vụ (Get-RgServiceMap), $Roots: workspace roots (tuỳ chọn).
function Get-RgProcIdentity($Row, $ByPid, $Cfg, $Services = $null, $Roots = $null) {
    $name = ([string]$Row.Name).ToLowerInvariant()
    # Danh tính của một tiến trình (PID + thời điểm khởi động) không đổi: cache để các lượt gọi sau gần như miễn phí (suy luận ~3 ms/tiến trình).
    $ck = $null
    if ([string]$Row.Start) {
        $ck = [string][int]$Row.Pid + '|' + [string]$Row.Start
        if ($name -eq 'svchost' -and $Services) { $ck += '|' + (@($Services[[int]$Row.Pid]) -join ',') }   # nhãn svchost phụ thuộc danh sách dịch vụ
        $cached = $script:RgIdCache[$ck]
        if ($cached -and ([datetime]::UtcNow.Ticks - $cached.at) -lt 6000000000) { return $cached.v }
    }
    $idc = Get-RgIdentityConfig $Cfg
    if ($null -eq $Roots) { $Roots = @(Get-RgWorkspaceRoots $Cfg.cleanup) }
    if ($null -eq $ByPid) { $ByPid = @{} }
    $cmd = [string]$Row.Cmd

    # chuỗi tổ tiên (gần nhất trước); dừng khi vòng lặp hoặc PID cha bị tái sử dụng (cha khởi động SAU con)
    $anc = New-Object System.Collections.ArrayList
    $seen = @{ ([int]$Row.Pid) = $true }
    $cur = $Row
    for ($i = 0; $i -lt 10; $i++) {
        $par = $ByPid[[int]$cur.ParentPid]
        if ($null -eq $par) { break }
        if ($seen.ContainsKey([int]$par.Pid)) { break }
        if ([string]$par.Start -and [string]$cur.Start -and [string]::CompareOrdinal([string]$par.Start, [string]$cur.Start) -gt 0) { break }
        $seen[[int]$par.Pid] = $true
        [void]$anc.Add($par); $cur = $par
    }

    # launcher gần nhất
    $owner = $null; $ownerIdx = -1
    for ($i = 0; $i -lt $anc.Count -and -not $owner; $i++) {
        $an = ([string]$anc[$i].Name).ToLowerInvariant()
        foreach ($l in @($idc.launchers)) {
            if ($an -eq [string]$l.name) { $owner = [pscustomobject]@{ name = [string]$anc[$i].Name; pid = [int]$anc[$i].Pid; label = [string]$l.label }; $ownerIdx = $i; break }
        }
    }
    $chainRows = New-Object System.Collections.ArrayList
    if ($owner) { for ($i = $ownerIdx; $i -ge 0; $i--) { [void]$chainRows.Add([string]$anc[$i].Name) } }
    else { for ($i = [math]::Min(2, $anc.Count - 1); $i -ge 0; $i--) { [void]$chainRows.Add([string]$anc[$i].Name) } }
    [void]$chainRows.Add([string]$Row.Name)
    $chain = @($chainRows)
    if ($chain.Count -gt 5) { $chain = @($chain[0]) + @($chain[($chain.Count - 4)..($chain.Count - 1)]) }

    # dự án: dòng lệnh của chính nó, rồi lần lượt các tổ tiên
    $proj = Find-RgProjectInCmd $cmd $Roots
    for ($i = 0; $i -lt $anc.Count -and -not $proj; $i++) { $proj = Find-RgProjectInCmd ([string]$anc[$i].Cmd) $Roots }

    # luật đầu tiên khớp
    $hit = $null; $arg = ''
    if (((Get-Date) - $script:RgIdRuleAt).TotalSeconds -gt 60) { $script:RgIdRuleByName = @{}; $script:RgIdRuleAt = Get-Date }
    $nameRules = $script:RgIdRuleByName[$name]
    if ($null -eq $nameRules) {   # chỉ giữ luật hợp với TÊN này; gọi hàm so tên cho từng luật x từng tiến trình rất chậm trong PS 5.1
        $nameRules = New-Object System.Collections.ArrayList
        foreach ($r in @($idc.rules)) { if (Test-RgIdName $name ([string]$r.name)) { [void]$nameRules.Add($r) } }
        $script:RgIdRuleByName[$name] = $nameRules
    }
    foreach ($r in $nameRules) {
        if ($r.PSObject.Properties['cmdRegex'] -and $r.cmdRegex) {
            if (-not $cmd) { continue }
            $m = (Get-RgIdRegex ([string]$r.cmdRegex)).Match($cmd)
            if (-not $m.Success) { continue }
            if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $arg = $m.Groups[1].Value }
        }
        $hit = $r; break
    }

    $role = 'unknown'; $title = [string]$Row.Name; $what = 'Chưa nhận diện được'; $conf = 'guess'
    if ($hit) {
        $role = [string]$hit.role; $title = [string]$hit.title
        $pn = $(if ($proj) { $proj.name } else { '(không rõ dự án)' })
        $what = ([string]$hit.what).Replace('{project}', $pn).Replace('{arg}', $(if ($arg) { $arg } else { '?' }))
        if (([string]$hit.what) -like '*{project}*' -and -not $proj) { $conf = 'guess' } else { $conf = 'rule' }
        if ($name -eq 'svchost' -and $Services) {
            $sv = @($Services[[int]$Row.Pid])
            if ($sv.Count -gt 0 -and $sv[0]) {
                $shown = @($sv | Select-Object -First 2) -join ', '
                $what = ('Chạy {0} dịch vụ Windows: {1}{2}' -f $sv.Count, $shown, $(if ($sv.Count -gt 2) { ' …' } else { '' }))
                $conf = 'rule'
            }
        }
    } else {
        switch ([string]$Row.Group) {
            'agent' { $role = 'agent'; $title = 'Trợ lý AI'; $what = 'Phiên làm việc của trợ lý AI'; $conf = 'guess' }
            'infra' { $role = 'infra'; $title = [string]$Row.Name; $what = 'Dịch vụ nền của hạ tầng phát triển'; $conf = 'guess' }
            default {
                if ($cmd -and $cmd -notmatch '^"?[A-Za-z]:\\Windows\\') { $role = 'app'; $what = 'Ứng dụng đang mở' }
            }
        }
    }

    $ownerName = $(if ($owner) { $owner.name } else { $null })
    $keyTail = $(if ($proj) { $proj.name } elseif ($ownerName) { $ownerName } else { $name })
    $res = [pscustomobject]([ordered]@{
            role = $role; title = $title; what = $what
            project = $(if ($proj) { $proj.name } else { $null }); projectPath = $(if ($proj) { $proj.path } else { $null })
            owner = $owner; chain = $chain
            workload = ($role + '|' + $keyTail)
            closeHint = (Get-RgIdentityCloseHint $role $owner $name)
            confidence = $conf
        })
    if ($ck) {
        if ($script:RgIdCache.Count -gt 4000) { $script:RgIdCache = @{} }
        $script:RgIdCache[$ck] = @{ at = [datetime]::UtcNow.Ticks; v = $res }
    }
    return $res
}

# ---------- D4: giải thích tiến trình (là gì, từ đâu, đang phục vụ việc gì) ----------
# Chỉ ĐỌC. Toàn bộ nội dung do luật tất định dựng từ dữ liệu có cấu trúc (danh tính, cây tiến trình, dịch vụ, file cài đặt, chữ ký số, ledger/lease);
# không có dòng lệnh nào đi ra ngoài và không cần AI. Kết quả dành cho người dùng xem trên máy mình (có đường dẫn cài đặt).

$script:RgSigCache = @{}
# Chữ ký số của một file thực thi: { signed; status; publisher }. Cache theo đường dẫn + ngày sửa (Get-AuthenticodeSignature ~vài chục ms).
function Get-RgFileSignature([string]$Path) {
    $none = [pscustomobject]@{ signed = $false; status = 'Unknown'; publisher = '' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $none }
    try {
        $key = $Path.ToLowerInvariant() + '|' + (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc.Ticks
        if ($script:RgSigCache.ContainsKey($key)) { return $script:RgSigCache[$key] }
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $pub = ''
        if ($s.SignerCertificate) { $m = [regex]::Match([string]$s.SignerCertificate.Subject, '(?:^|,\s*)CN=("([^"]+)"|[^,]+)'); if ($m.Success) { $pub = $(if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[1].Value.Trim() }) } }
        $r = [pscustomobject]@{ signed = ([string]$s.Status -eq 'Valid'); status = [string]$s.Status; publisher = $pub }
        if ($script:RgSigCache.Count -gt 500) { $script:RgSigCache = @{} }
        $script:RgSigCache[$key] = $r
        return $r
    } catch { return $none }
}

function Format-RgUptimeVi([datetime]$StartLocal) {
    $m = [int][math]::Max(0, ((Get-Date) - $StartLocal).TotalMinutes)
    if ($m -lt 2) { return 'vừa mới bắt đầu' }
    if ($m -lt 120) { return "$m phút" }
    if ($m -lt 2880) { return ('{0:n0} giờ' -f [math]::Floor($m / 60.0)) }
    return ('{0:n0} ngày' -f [math]::Floor($m / 1440.0))
}

# Trả { ok; error } nếu không giải thích được (PID đã chết hoặc bị tái sử dụng), ngược lại bản giải thích có cấu trúc kèm 'text'.
function Get-RgProcExplain {
    param([int]$ProcId, [string]$Start = '', $Cfg = $null, $Table = $null, $Ctx = $null)
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($ProcId -le 0) { return [pscustomobject]@{ ok = $false; error = 'PID không hợp lệ.' } }
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
    if (-not $c) { return [pscustomobject]@{ ok = $false; error = 'Tiến trình không còn chạy.' } }
    $stamp = ConvertTo-RgStamp $c.CreationDate
    if ($Start -and $stamp -ne $Start) { return [pscustomobject]@{ ok = $false; error = 'Tiến trình đã thay đổi (PID được dùng lại). Hãy tải lại danh sách.' } }
    if ($null -eq $Table) { $Table = @($script:RgTableCache) }
    if (@($Table | Where-Object { $_ }).Count -eq 0) { $Table = @(Get-RgProcessTable) }
    $by = @{}; foreach ($t in @($Table)) { if ($t) { $by[[int]$t.Pid] = $t } }
    $name = ([string]$c.Name -replace '\.exe$', '').ToLowerInvariant()
    $cmd = [string]$c.CommandLine
    $row = $by[$ProcId]
    if ($null -eq $row -or [string]$row.Start -ne $stamp) {
        $row = [pscustomobject]@{ Pid = $ProcId; ParentPid = [int]$c.ParentProcessId; Name = $name; Start = $stamp; Cmd = $cmd; Group = (Get-RgGroup $name $cmd $Cfg) }
        $by[$ProcId] = $row
    }
    $roots = @(Get-RgWorkspaceRoots $Cfg.cleanup)
    $svcMap = Get-RgServiceMap
    $idn = Get-RgProcIdentity $row $by $Cfg $svcMap $roots
    $services = @($svcMap[$ProcId] | Where-Object { $_ })

    # cha trực tiếp (bỏ qua nếu cha khởi động SAU con = PID bị tái sử dụng)
    $parent = $null
    $pr = $by[[int]$row.ParentPid]
    if ($pr -and [int]$pr.Pid -ne $ProcId -and -not ([string]$pr.Start -and [string]::CompareOrdinal([string]$pr.Start, $stamp) -gt 0)) { $parent = [pscustomobject]@{ pid = [int]$pr.Pid; name = [string]$pr.Name } }

    # file cài đặt + chữ ký
    $exe = [string]$c.ExecutablePath; $company = ''; $product = ''
    if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
        try { $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe); $company = [string]$vi.CompanyName; $product = [string]$vi.ProductName } catch { }
    }
    $sig = Get-RgFileSignature $exe
    $install = $(if ($exe) { Split-Path $exe -Parent } else { '' })

    # đang phục vụ việc gì: ledger (agent tự đăng ký) > quan sát từ cây tiến trình của phiên giữ lease > hậu duệ của chủ lease
    if ($null -eq $Ctx) { $Ctx = New-RgProcContext -Cfg $Cfg -Table $Table }
    $serving = [pscustomobject]@{ kind = 'none'; agent = ''; label = ''; detail = '' }
    $le = $Ctx.ledgerEntries[$ProcId]
    if ($le -and [string]$le.start -eq $stamp) {
        $serving = [pscustomobject]@{ kind = 'ledger'; agent = [string]$le.agent; label = [string]$le.label; detail = "Do trợ lý AI '$($le.agent)' đăng ký" + $(if ($le.label) { ": $($le.label)" } else { '' }) }
    } elseif ($Ctx.observed.ContainsKey($ProcId)) {
        $o = $Ctx.observed[$ProcId]
        $serving = [pscustomobject]@{ kind = 'observed'; agent = [string]$o.agent; label = [string]$o.group; detail = "Là tiến trình $($o.group) chạy trong phiên của trợ lý AI '$($o.agent)' (nhìn thấy qua cây tiến trình)" }
    }

    $role = [string]$idn.role
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add(("{0}: {1}." -f $idn.title, ([string]$idn.what).TrimEnd('.')))
    if ($services.Count -gt 0) { [void]$parts.Add(('Đây là tiến trình dịch vụ Windows ({0}).' -f ((@($services | Select-Object -First 3)) -join ', '))) }
    if (@($idn.chain).Count -gt 1) { [void]$parts.Add(('Được mở theo chuỗi: {0}.' -f ((@($idn.chain)) -join ' → '))) }
    elseif ($parent) { [void]$parts.Add(('Được mở bởi {0}.' -f $parent.name)) }
    if ($idn.project) { [void]$parts.Add(('Thuộc dự án "{0}".' -f $idn.project)) }
    if ($serving.kind -ne 'none') { [void]$parts.Add($serving.detail + '.') }
    if ($exe) {
        $who = $(if ($sig.signed) { 'có chữ ký số hợp lệ' + $(if ($sig.publisher) { " của $($sig.publisher)" } else { '' }) }
            elseif ($sig.status -eq 'NotSigned') { 'không có chữ ký số' } elseif ($sig.status -eq 'Unknown') { 'chưa kiểm được chữ ký số' } else { "chữ ký số không hợp lệ ($($sig.status))" })
        [void]$parts.Add(('Chạy từ {0}; file {1}.' -f $install, $who))
    }
    [void]$parts.Add(('Đã chạy {0}.' -f (Format-RgUptimeVi $c.CreationDate)))
    if ($idn.closeHint) { [void]$parts.Add(([string]$idn.closeHint).TrimEnd('.') + '.') }
    $sources = @('luật nhận diện')
    if (@($idn.chain).Count -gt 1 -or $parent) { $sources += 'cây tiến trình' }
    if ($services.Count -gt 0) { $sources += 'danh sách dịch vụ' }
    if ($exe) { $sources += 'file cài đặt và chữ ký số' }
    if ($serving.kind -ne 'none') { $sources += $(if ($serving.kind -eq 'ledger') { 'sổ tiến trình của agent' } else { 'phiên agent đang giữ lease' }) }

    return [pscustomobject][ordered]@{
        ok = $true; pid = $ProcId; start = $stamp; name = $name; title = [string]$idn.title; role = $role; what = [string]$idn.what; confidence = [string]$idn.confidence
        chain = @($idn.chain); parent = $parent; services = @($services); project = $idn.project
        install = [pscustomobject]@{ dir = $install; company = $company; product = $product; signed = [bool]$sig.signed; signStatus = [string]$sig.status; publisher = [string]$sig.publisher }
        serving = $serving; uptimeText = (Format-RgUptimeVi $c.CreationDate); closeHint = [string]$idn.closeHint
        text = ($parts -join ' '); sources = $sources
    }
}

# Gộp các dòng (đã có .identity) theo khoá workload -> sắp theo RAM giảm dần.
# Dòng đầu vào: { pid; ramMB; cpu; protected; identity }.
function Get-RgWorkloads($Rows) {
    $g = @{}
    foreach ($r in @($Rows)) {
        if (-not $r -or -not $r.identity) { continue }
        $k = [string]$r.identity.workload
        if (-not $g.ContainsKey($k)) {
            $g[$k] = [ordered]@{ key = $k; role = $r.identity.role; title = $r.identity.title; project = $r.identity.project; owner = $r.identity.owner
                what = $r.identity.what; closeHint = $r.identity.closeHint; count = 0; ramMB = 0.0; cpuPct = 0.0; pids = (New-Object System.Collections.ArrayList); protected = $false }
        }
        $e = $g[$k]; $e.count++; $e.ramMB += [double]$r.ramMB; $e.cpuPct += [double]$r.cpu
        [void]$e.pids.Add([int]$r.pid)
        if ($r.protected) { $e.protected = $true }
    }
    return @($g.Values | ForEach-Object {
            [ordered]@{ key = $_.key; role = $_.role; title = $_.title; project = $_.project; owner = $_.owner; what = $_.what; closeHint = $_.closeHint; count = $_.count
                ramMB = [int][math]::Round($_.ramMB); cpuPct = [math]::Round($_.cpuPct, 1); pids = @($_.pids); protected = $_.protected }
        } | Sort-Object { $_.ramMB } -Descending)
}

# Bảng PID -> khoá workload cho cả bảng tiến trình (watcher dùng để gắn vào procTop).
function Get-RgWorkloadMap($Table, $Cfg = $null) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    $by = @{}; foreach ($t in @($Table)) { if ($t) { $by[[int]$t.Pid] = $t } }
    $roots = @(Get-RgWorkspaceRoots $Cfg.cleanup)
    $svc = Get-RgServiceMap
    $map = @{}
    foreach ($t in @($Table)) {
        if (-not $t) { continue }
        try { $map[[int]$t.Pid] = [string](Get-RgProcIdentity $t $by $Cfg $svc $roots).workload } catch { }
    }
    return $map
}

# Workload của các tiến trình đang chạy (dữ liệu sống của watcher: $script:RgLastProcs + $script:RgTableCache). Dùng cho /api/advice.
function Get-RgLiveWorkloads($Policy = $null) {
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    $cfg = Get-RgConfig
    $by = @{}; foreach ($t in @($script:RgTableCache)) { if ($t) { $by[[int]$t.Pid] = $t } }
    $roots = @(Get-RgWorkspaceRoots $cfg.cleanup); $svc = Get-RgServiceMap
    $rows = foreach ($p in @($script:RgLastProcs)) {
        $tr = $by[[int]$p.pid]
        $row = $(if ($tr) { $tr } else { [pscustomobject]@{ Pid = [int]$p.pid; ParentPid = 0; Name = [string]$p.name; Start = ''; Cmd = ''; Group = [string]$p.group } })
        $id = $null; try { $id = Get-RgProcIdentity $row $by $cfg $svc $roots } catch { }
        if ($id) { [pscustomobject]@{ pid = [int]$p.pid; ramMB = $p.ramMB; cpu = $p.cpu; protected = (Test-RgProcessProtected ([string]$p.name) $Policy); identity = $id } }
    }
    return @(Get-RgWorkloads @($rows))
}
