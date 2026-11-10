# rg-proc.ps1 - HẠ ƯU TIÊN tiến trình (đảo ngược được). Dot-source sau rg-common.ps1 và rg-policy.ps1.
# KHÔNG có đường kết thúc tiến trình nào ở đây: chỉ đổi PriorityClass Normal <-> BelowNormal.
# An toàn: mọi kiểm tra thuộc về MỘT hàm quyết định (Get-RgProcLowerVerdict) dùng chung cho danh sách (canLower/whyNot) và cho lúc thực thi,
# nên nút trên UI và việc server thực sự làm luôn khớp. Lúc thực thi còn kiểm lại bằng dữ liệu sống (PID + start time + tên + mức hiện tại).

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
function New-RgProcContext($Cfg = $null, $Policy = $null, [switch]$FreshSelf) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    $ledger = @{}; foreach ($e in @(Read-RgLedger)) { if ($e.pid) { $ledger[[int]$e.pid] = $true } }
    $lowered = @{}; foreach ($e in @(Read-RgProcPriority)) { $lowered["$([int]$e.pid)|$([string]$e.start)"] = $e }
    return [pscustomobject]@{
        cfg = $Cfg; policy = $Policy; ledger = $ledger; lowered = $lowered
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
