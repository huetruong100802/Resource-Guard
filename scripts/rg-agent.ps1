# rg-agent.ps1 - "nhờ agent đánh giá": gửi METADATA (không gửi nội dung file) cho `claude -p` (haiku, effort high), nhận JSON có cấu trúc.
#   Dot-source: nạp New-RgAgentPayload (UI dùng để xem trước dữ liệu sẽ gửi).
#   Chạy trực tiếp: rg-agent.ps1 [-TimeoutSec 180] [-MaxBudgetUsd 0.5]   -> state\agent-last.json, tiến độ state\agent.progress.json
# Agent chỉ GỢI Ý. Tool giữ sự thật; mọi key agent trả về được đối chiếu lại với danh sách ứng viên, key lạ bị loại.
[CmdletBinding()]
param([int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Model = 'haiku', [string]$Effort = 'high')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')

function ConvertTo-RgSafeText([string]$S) {   # không để lộ tên tài khoản Windows
    if (-not $S) { return $S }
    $u = [string]$env:USERPROFILE
    if ($u) { $S = $S.Replace($u, '~') }
    return $S
}

function Read-RgJsonState([string]$Name) {
    $p = Join-Path (Initialize-RgHome) ("state\" + $Name)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json (Read-RgFileShared $p)) } catch { return $null }
}

function New-RgAgentPayload {
    $cfg = Get-RgConfig
    $policy = Get-RgPolicy
    $live = Read-RgJsonState 'live.json'
    $bds = @(Get-ChildItem -LiteralPath (Join-Path (Initialize-RgHome) 'state') -Filter 'scan-breakdown-?.json' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Read-RgJsonState $_.Name } | Where-Object { $_ })
    $cd = Read-RgJsonState 'scan-candidates.json'
    $now = (Get-Date).ToUniversalTime()
    $ageOf = { param($iso) if (-not $iso) { return $null } try { [int][math]::Floor(($now - [datetime]::Parse([string]$iso, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime()).TotalDays) } catch { $null } }

    $machine = $null; $procs = $null
    if ($live) {
        $machine = [ordered]@{
            state = $live.state; ramTotalGB = $live.totalRamGB; ramAvailGB = $live.availRamGB; commitPct = $live.commitPct; cpuPct = $live.cpuPct
            diskDrive = $live.diskDrive; diskFreeGB = $live.diskFreeGB
            drives = @($live.drives | ForEach-Object { [ordered]@{ drive = $_.drive; totalGB = $_.totalGB; freeGB = $_.freeGB; state = $_.state; isSystem = [bool]$_.isSystem } })
            uptimeHours = $(if ($live.uptimeSec) { [math]::Round([double]$live.uptimeSec / 3600, 1) } else { $null })
            reasons = @($live.reasons)
        }
        $procs = [ordered]@{
            count = $live.procCount
            topCpu = @($live.topCpu | Select-Object -First 8 | ForEach-Object { [ordered]@{ name = $_.name; cpuPct = $_.cpu; ramMB = $_.ramMB } })
            topRam = @($live.top | Select-Object -First 5 | ForEach-Object { [ordered]@{ name = $_.name; ramMB = $_.ramMB } })
        }
    }
    $disks = @()
    foreach ($bd in $bds) {
        $cats = @($bd.categories | ForEach-Object {
                [ordered]@{
                    category = $_.cat; gb = [math]::Round([double]$_.bytes / 1GB, 2); files = $_.files
                    top = @($_.items | Select-Object -First 8 | ForEach-Object { [ordered]@{ item = (ConvertTo-RgSafeText ([string]$_.key)); gb = [math]::Round([double]$_.bytes / 1GB, 2); idleDays = (& $ageOf $_.newestUtc) } })
                }
            })
        $disks += [ordered]@{
            drive = $bd.drive; totalGB = [math]::Round([double]$bd.totalBytes / 1GB, 1); freeGB = [math]::Round([double]$bd.freeBytes / 1GB, 1)
            unscannedGB = [math]::Round([double]$bd.unscannedBytes / 1GB, 1); scannedAgeHours = [math]::Round(($now - [datetime]::Parse([string]$bd.finishedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime()).TotalHours, 1)
            categories = $cats
        }
    }
    $cands = @()
    if ($cd) {
        $sorted = @($cd.items | Sort-Object { [long]$_.sizeBytes } -Descending | Select-Object -First 50)
        $cands = @($sorted | ForEach-Object {
                $tgt = if ($_.kind -eq 'process') { "$($_.name) (pid $($_.pid))" } else { (ConvertTo-RgSafeText ([string]$_.path)) }
                $prot = if ($_.kind -eq 'process') { Test-RgProcessProtected ([string]$_.name) $policy } else { Test-RgPathProtected ([string]$_.path) $policy }
                [ordered]@{ key = $_.key; kind = $_.kind; action = $_.action; target = $tgt; sizeMB = [math]::Round([double]$_.sizeBytes / 1MB, 0); idleDays = $_.ageDays
                    toolRisk = $_.risk; toolReason = $_.reason; userProtected = [bool]$prot }
            })
    }
    return [ordered]@{
        generatedUtc = $now.ToString('o')
        thresholds = [ordered]@{ ramAvailGB = $cfg.ram; diskFreeGB = $cfg.disk }
        machine = $machine; processes = $procs; disks = $disks; cleanupCandidates = $cands
        policySummary = [ordered]@{
            mode = $policy.mode; categories = $policy.categories; protectedPathCount = @($policy.protectPaths).Count
            protectedProcessNames = @($policy.protectProcesses)
        }
        notes = @(
            $(if ($disks.Count -eq 0) { 'Chưa có dữ liệu quét ổ đĩa.' }), $(if (-not $cd) { 'Chưa có danh sách ứng viên dọn dẹp.' })
        ) | Where-Object { $_ }
    }
}

$script:RgAgentSchema = '{"type":"object","additionalProperties":false,"properties":{"summary":{"type":"string"},"severity":{"type":"string","enum":["ok","watch","act"]},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"area":{"type":"string","enum":["disk","ram","cpu","process","policy"]},"title":{"type":"string"},"detail":{"type":"string"}},"required":["area","title","detail"]}},"recommendations":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"key":{"type":"string"},"verdict":{"type":"string","enum":["clean","keep","review"]},"priority":{"type":"integer"},"confidence":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["key","verdict","priority","confidence","reason"]}},"policySuggestions":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string"},"setting":{"type":"string","enum":["auto","ask","keep"]},"reason":{"type":"string"}},"required":["kind","setting","reason"]}}},"required":["summary","severity","findings","recommendations","policySuggestions"]}'

function Get-RgAgentPrompt([string]$PayloadJson) {
    return @"
Bạn là trợ lý đánh giá tài nguyên máy Windows cho công cụ Resource Guard. Công cụ đã đo toàn bộ sự thật; bạn chỉ ĐÁNH GIÁ và GỢI Ý, con người quyết định.

Quy tắc bắt buộc:
- Chỉ dùng dữ liệu JSON bên dưới. Không bịa số liệu, không suy đoán nội dung file (bạn chỉ thấy tên, kích thước, số ngày không dùng).
- "recommendations[].key" CHỈ được lấy từ "cleanupCandidates[].key". Mục có userProtected=true thì verdict phải là "keep".
- Chỉ đề xuất verdict "clean" cho mục có action là delete hoặc kill. Mục action=report chỉ được "keep" hoặc "review".
- Ưu tiên (priority 1 = làm trước, 5 = sau cùng) theo dung lượng thu hồi, mức rủi ro và số ngày không dùng.
- "findings": các nhân tố chiếm ổ đĩa lớn/bất thường (disks[].categories, mỗi phần tử là một ổ; so sánh giữa các ổ khi có nhiều ổ), tiến trình ngốn CPU/RAM bất thường, dữ liệu quét đã cũ hoặc thiếu. Mỗi finding nêu rõ con số.
- "policySuggestions": mỗi phần tử là MỘT THAY ĐỔI so với policySummary.categories hiện tại cho kind (temp-entry, dotnet-artifact, cache-aged, node_modules, process); "setting" là chế độ MỚI (auto = tự dọn khi có áp lực, ask = chỉ hỏi tay, keep = không bao giờ đụng). Chỉ đưa khi setting KHÁC chế độ hiện tại và có lý do từ dữ liệu; thường để trống. "reason" giải thích vì sao đổi, không nhắc lại chế độ cũ.
- Viết tiếng Việt, ngắn gọn, không quá 25 từ mỗi lý do. Tối đa 8 findings và 15 recommendations.

DỮ LIỆU:
$PayloadJson
"@
}

function Invoke-RgAgentEval {
    param([int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Model = 'haiku', [string]$Effort = 'high')
    $payload = New-RgAgentPayload
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $prompt = Get-RgAgentPrompt $json
    $cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw 'Không tìm thấy lệnh `claude` trong PATH.' }
    $cwd = Join-Path (Initialize-RgHome) 'state\agent-cwd'
    [void](New-Item -ItemType Directory -Force -Path $cwd)

    $schemaArg = $script:RgAgentSchema.Replace('"', '\"')
    $args_ = "-p --model $Model --effort $Effort --tools `"`" --output-format json --no-session-persistence --disable-slash-commands --setting-sources project --max-budget-usd $MaxBudgetUsd --json-schema `"$schemaArg`""
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source; $psi.Arguments = $args_; $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync(); $errT = $p.StandardError.ReadToEndAsync()
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($prompt)
    try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush() } catch { }
    try { $p.StandardInput.Close() } catch { }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; throw "claude không trả lời sau $TimeoutSec giây (đã dừng)." }
    $out = $outT.Result; $err = $errT.Result
    $res = $null
    try { $res = ConvertFrom-Json $out } catch { throw ("Không đọc được JSON từ claude (exit $($p.ExitCode)): " + (($err + ' ' + $out).Trim() | Select-Object -First 1).ToString().Substring(0, [math]::Min(300, ($err + ' ' + $out).Trim().Length))) }
    if ($res.is_error -or -not $res.structured_output) { throw ("claude báo lỗi: " + [string]$res.result) }

    $so = $res.structured_output
    $keys = @{}; foreach ($c in @($payload.cleanupCandidates)) { $keys[[string]$c.key] = $c }
    $kept = @(); $dropped = 0
    foreach ($r in @($so.recommendations)) {
        $c = $keys[[string]$r.key]
        if (-not $c) { $dropped++; continue }
        $verdict = [string]$r.verdict
        if ($c.userProtected) { $verdict = 'keep' }
        elseif ($verdict -eq 'clean' -and $c.action -eq 'report') { $verdict = 'review' }
        $kept += [pscustomobject]@{ key = $r.key; verdict = $verdict; priority = [int][math]::Min(5, [math]::Max(1, [int]$r.priority)); confidence = $r.confidence; reason = $r.reason }
    }
    $curCats = (Get-RgPolicy).categories
    $pol = @($so.policySuggestions | Where-Object { ($script:RgPolicyKinds -contains [string]$_.kind) -and ([string]$curCats[[string]$_.kind] -ne [string]$_.setting) })
    return [ordered]@{
        ok = $true; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); model = $Model; effort = $Effort
        costUsd = $res.total_cost_usd; durationMs = $res.duration_ms; payloadBytes = $bytes.Length
        result = [ordered]@{ summary = $so.summary; severity = $so.severity; findings = @($so.findings); recommendations = $kept; policySuggestions = $pol; droppedUnknownKeys = $dropped }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-source: chỉ nạp hàm

$jobFile = 'agent.progress.json'; $started = (Get-Date).ToUniversalTime().ToString('o')
function Set-Job([string]$Status, [string]$Msg = '') {
    Write-RgJobState $jobFile ([ordered]@{ pid = $PID; status = $Status; message = $Msg; startedUtc = $started; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
}
try {
    $cur = Get-RgJobState $jobFile
    if ($cur -and $cur.status -eq 'running' -and [int]$cur.pid -ne $PID) { return }
    Set-Job 'running' 'đang gọi claude (haiku, high)'
    $r = Invoke-RgAgentEval -TimeoutSec $TimeoutSec -MaxBudgetUsd $MaxBudgetUsd -Model $Model -Effort $Effort
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\agent-last.json') (ConvertTo-Json -InputObject $r -Depth 8 -Compress)
    Write-RgLog 'agent-eval' ([ordered]@{ ok = $true; costUsd = $r.costUsd; durationMs = $r.durationMs; payloadBytes = $r.payloadBytes })
    Set-Job 'done' ('xong, chi phí $' + $r.costUsd)
}
catch {
    $msg = [string]$_.Exception.Message
    Write-RgLog 'agent-error' $msg
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\agent-last.json') (ConvertTo-Json -InputObject ([ordered]@{ ok = $false; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = $msg }) -Compress)
    Set-Job 'error' $msg
    exit 1
}
