# rg-agent.ps1 - "nhờ agent đánh giá": gửi METADATA (không gửi nội dung file) cho nhà cung cấp AI đang chọn (rg-agents.ps1), nhận JSON có cấu trúc.
#   Dot-source: nạp New-RgAgentPayload (UI dùng để xem trước dữ liệu sẽ gửi).
#   Chạy trực tiếp: rg-agent.ps1 [-TimeoutSec 180] [-MaxBudgetUsd 0.5]   -> state\agent-last.json, tiến độ state\agent.progress.json
# Agent chỉ GỢI Ý. Tool giữ sự thật; mọi key agent trả về được đối chiếu lại với danh sách ứng viên, key lạ bị loại.
[CmdletBinding()]
param([int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Model = 'haiku', [string]$Effort = 'high', [ValidateSet('eval', 'clusters')][string]$Mode = 'eval')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
. (Join-Path $PSScriptRoot 'rg-insight.ps1')

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
    # Kế hoạch tất định của máy: agent biết thứ tự máy đã lập và nhóm "cần xem lại" (máy không tự quyết được) để ưu tiên đánh giá.
    $advSteps = @(); $revKeys = @()
    try {
        $dr = if ($live -and $live.drives) { @($live.drives) } else { $null }
        $adv = Get-RgAdvice -Drives $dr
        $advSteps = @($adv.steps | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; bytes = $_.bytes; riskLevel = $_.riskLevel } })
        $revKeys = @($adv.review.keys | Where-Object { $_ })
    } catch { }
    $cands = @()
    if ($cd) {
        $sorted = @($cd.items | Sort-Object { [long]$_.sizeBytes } -Descending | Select-Object -First 50)
        if ($revKeys.Count) {   # mục cần xem lại luôn được gửi (thêm tối đa 20) để key agent trả về còn hợp lệ
            $have = @{}; foreach ($s in $sorted) { $have[[string]$s.key] = $true }
            $sorted += @($cd.items | Where-Object { $revKeys -contains [string]$_.key -and -not $have.ContainsKey([string]$_.key) } | Select-Object -First 20)
        }
        $cands = @($sorted | ForEach-Object {
                $tgt = if ($_.kind -eq 'process') { "$($_.name) (pid $($_.pid))" } else { (ConvertTo-RgSafeText ([string]$_.path)) }
                $prot = if ($_.kind -eq 'process') { Test-RgProcessProtected ([string]$_.name) $policy } else { Test-RgPathUserProtected ([string]$_.path) $policy }
                $ak = if ($_.kind -eq 'process') { $null } else { Get-RgAgentKeepMatch ([string]$_.path) }
                [ordered]@{ key = $_.key; kind = $_.kind; action = $_.action; target = $tgt; sizeMB = [math]::Round([double]$_.sizeBytes / 1MB, 0); idleDays = $_.ageDays; belowAgeFloor = [bool]$_.young
                    toolRisk = $_.risk; toolReason = $_.reason; userProtected = [bool]$prot; agentKept = [bool]$ak }
            })
    }
    return [ordered]@{
        generatedUtc = $now.ToString('o')
        thresholds = [ordered]@{ ramAvailGB = $cfg.ram; diskFreeGB = $cfg.disk }
        machine = $machine; processes = $procs; disks = $disks; cleanupCandidates = $cands
        advice = [ordered]@{ steps = $advSteps }; review = [ordered]@{ keys = $revKeys }
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
- "recommendations[].key" CHỈ được lấy từ "cleanupCandidates[].key". Mục có userProtected=true hoặc agentKept=true thì verdict phải là "keep".
- Verdict "keep" kèm confidence "high" sẽ được công cụ GHI NHẬN thành bảo vệ có thời hạn 30 ngày: mục đó bị ẩn khỏi danh sách dọn và không bao giờ tự dọn (chỉ áp cho đường dẫn, không áp cho tiến trình). Chỉ dùng "keep"+"high" khi có tín hiệu rõ là nên giữ: dự án đang làm (số ngày không dùng thấp, node_modules/bin/obj của repo gần đây), dữ liệu khó hoặc đắt để sinh lại, hoặc rủi ro mất dữ liệu cao. Chưa chắc thì dùng confidence "medium"/"low" hoặc verdict "review". Mục thật sự rác, sinh lại dễ thì "clean", đừng "keep" cho an toàn.
- Chỉ đề xuất verdict "clean" cho mục có action là delete hoặc kill. Mục action=report chỉ được "keep" hoặc "review".
- Số ngày không dùng chỉ là MỘT tín hiệu, không phải điều kiện quyết định. Mục có belowAgeFloor=true chưa đủ tuổi theo policy nhưng vẫn được đưa vào để bạn cân nhắc: có thể "clean" nếu loại mục sinh lại được dễ (build output, cache tải lại được), dung lượng đáng kể và disk đang thiếu; nên "keep"/"review" nếu có dấu hiệu đang dùng (tiến trình build/dev đang chạy, node_modules của dự án đang làm, rủi ro cao). Với mục belowAgeFloor, "reason" phải nêu lý do vì sao tuổi thấp vẫn xoá được (hoặc không). Người dùng luôn là người duyệt cuối cùng; mục này không bao giờ tự xoá.
- Ưu tiên (priority 1 = làm trước, 5 = sau cùng) theo dung lượng thu hồi, mức rủi ro và số ngày không dùng.
- "review.keys" là các mục máy KHÔNG tự quyết được (chưa đủ tuổi, cần quyền admin...). Hãy đánh giá các key này TRƯỚC, mỗi key một recommendation. "advice.steps" là thứ tự dọn tất định máy đã lập; đừng lặp lại nó, chỉ nhận xét khi bạn thấy bước nào nên đổi.
- "summary" phải trả lời thẳng "nên làm gì trước và vì sao" trong 1-2 câu ngắn, dựa trên số liệu (vd: ổ nào thiếu, bước nào đủ mục tiêu, mục nào cần giữ).
- "findings": các nhân tố chiếm ổ đĩa lớn/bất thường (disks[].categories, mỗi phần tử là một ổ; so sánh giữa các ổ khi có nhiều ổ), tiến trình ngốn CPU/RAM bất thường, dữ liệu quét đã cũ hoặc thiếu. Mỗi finding nêu rõ con số.
- "policySuggestions": mỗi phần tử là MỘT THAY ĐỔI so với policySummary.categories hiện tại cho kind (temp-entry, dotnet-artifact, cache-aged, node_modules, process); "setting" là chế độ MỚI (auto = tự dọn khi có áp lực, ask = chỉ hỏi tay, keep = không bao giờ đụng). Chỉ đưa khi setting KHÁC chế độ hiện tại và có lý do từ dữ liệu; thường để trống. "reason" giải thích vì sao đổi, không nhắc lại chế độ cũ.
- Viết tiếng Việt, ngắn gọn, không quá 25 từ mỗi lý do. Tối đa 8 findings và 15 recommendations.

DỮ LIỆU:
$PayloadJson
"@
}

# Gọi nhà cung cấp AI đang chọn (rg-agents.ps1: claude | codex | gemini | ollama | API tương thích OpenAI) với prompt + JSON schema.
# Trả { so; costUsd; durationMs; bytes; provider; label; model; local }. `so` đã qua kiểm dạng; ném lỗi nếu không có nhà cung cấp/hết giờ/sai dạng.
# -Model/-Effort chỉ là gợi ý cho nhà cung cấp hiểu được (claude); nhà cung cấp khác dùng model khai trong config.
function Invoke-RgEvaluatorJson {
    param([string]$Prompt, [string]$Schema, [int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Model = '', [string]$Effort = 'high')
    $p = Get-RgEvaluator
    if (-not $p) { throw 'Chưa có nhà cung cấp AI nào dùng được. Xem Cài đặt > Kết nối agent.' }
    $useModel = $(if ($p.id -eq 'claude' -and $Model -and -not (Read-RgEvaluatorChoice).model) { $Model } else { '' })
    $r = Invoke-RgLlmJson -Prompt $Prompt -Schema $Schema -Provider $p -TimeoutSec $TimeoutSec -MaxBudgetUsd $MaxBudgetUsd -Effort $Effort -Model $useModel
    return [pscustomobject]@{ so = $r.data; costUsd = $r.costUsd; durationMs = $r.durationMs; bytes = $r.bytes; provider = $r.provider; label = $r.label; model = $r.model; local = $r.local }
}

# Đánh giá CỤM (D3): chỉ gửi metadata cụm (không đường dẫn, không tên file). Kết quả đi qua ConvertTo-RgSafeVerdicts rồi được nhớ theo verdictKey.
$script:RgClusterSchema = '{"type":"object","additionalProperties":false,"properties":{"verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"clusterId":{"type":"string"},"verdict":{"type":"string","enum":["keep","compress","clean"]},"confidence":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["clusterId","verdict","confidence","reason"]}}},"required":["verdicts"]}'

function Invoke-RgClusterAgentEval {
    param([int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.3, [string]$Model = 'haiku', [string]$Effort = 'medium')
    $cfg = Get-RgConfig
    $rep = Get-RgAssistantReport $cfg
    if (-not $rep.scanned) { throw 'Chưa kiểm kê; hãy quét trước.' }
    $payload = New-RgClusterAgentPayload @($rep.clusters) $cfg
    if (@($payload.clusters).Count -eq 0) { return [ordered]@{ ok = $true; asked = 0; message = 'Không có cụm nào cần hỏi thêm (đã có verdict còn mới).' } }
    $prompt = @"
Bạn là trợ lý đánh giá file cá nhân cho công cụ Resource Guard trên Windows. Công cụ đã gom file thành CỤM và chỉ cho bạn metadata (họ file, đuôi, số tệp, MB, số ngày chưa đụng, thư mục chứa, % tải từ web). Bạn KHÔNG thấy tên hay nội dung file.
Quy tắc bắt buộc:
- Mỗi phần tử "verdicts" phải có clusterId lấy từ dữ liệu. Id lạ sẽ bị loại.
- verdict: "keep" (giữ), "compress" (nén zip có kiểm tra, khôi phục được), "clean" (xoá; CHỈ hợp lý cho bộ cài đã tải hoặc file tạm, tải/sinh lại được). Tài liệu, bảng tính, ảnh, video, mã nguồn, cơ sở dữ liệu: tối đa là "compress", công cụ sẽ tự hạ "clean" xuống "compress".
- "ruleVerdict" là gợi ý tất định của công cụ; chỉ khác nó khi có lý do từ số liệu. Nghi ngờ thì "keep" với confidence "low".
- Cụm chưa đụng dưới 30 ngày luôn "keep".
- reason: tiếng Việt, tối đa 20 từ, nêu con số.
DỮ LIỆU:
$(ConvertTo-Json -InputObject $payload -Depth 5 -Compress)
"@
    $r = Invoke-RgEvaluatorJson -Prompt $prompt -Schema $script:RgClusterSchema -TimeoutSec $TimeoutSec -MaxBudgetUsd $MaxBudgetUsd -Model $Model -Effort $Effort
    $safe = ConvertTo-RgSafeVerdicts @($r.so.verdicts) @($rep.clusters) $cfg
    $cache = Read-RgVerdictCache
    $byId = @{}; foreach ($c in @($rep.clusters)) { $byId[[string]$c.clusterId] = $c }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($v in @($safe.verdicts)) { $cache[[string]$byId[[string]$v.clusterId].verdictKey] = [pscustomobject]@{ verdict = $v.verdict; reason = $v.reason; confidence = $v.confidence; ts = $now } }
    Save-RgVerdictCache $cache
    return [ordered]@{ ok = $true; asked = @($payload.clusters).Count; accepted = @($safe.verdicts).Count; dropped = $safe.dropped; omitted = $payload.omitted; costUsd = $r.costUsd; durationMs = $r.durationMs; payloadBytes = $r.bytes; provider = $r.provider; model = $r.model }
}

function Invoke-RgAgentEval {
    param([int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Model = 'haiku', [string]$Effort = 'high')
    $payload = New-RgAgentPayload
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $prompt = Get-RgAgentPrompt $json
    $lr = Invoke-RgEvaluatorJson -Prompt $prompt -Schema $script:RgAgentSchema -TimeoutSec $TimeoutSec -MaxBudgetUsd $MaxBudgetUsd -Model $Model -Effort $Effort

    $so = $lr.so
    $keys = @{}; foreach ($c in @($payload.cleanupCandidates)) { $keys[[string]$c.key] = $c }
    $kept = @(); $dropped = 0; $keptApplied = 0
    $rawByKey = @{}   # đường dẫn thật (payload đã thay tên tài khoản bằng ~); chỉ lấy từ file quét của tool, không từ agent
    foreach ($ri in @((Read-RgJsonState 'scan-candidates.json').items)) { $rawByKey[[string]$ri.key] = $ri }
    foreach ($r in @($so.recommendations)) {
        $c = $keys[[string]$r.key]
        if (-not $c) { $dropped++; continue }
        $verdict = [string]$r.verdict
        $autoKept = $false
        if ($c.userProtected -or $c.agentKept) { $verdict = 'keep' }
        elseif ($verdict -eq 'clean' -and $c.action -eq 'report') { $verdict = 'review' }
        elseif ($verdict -eq 'keep' -and [string]$r.confidence -eq 'high' -and $c.kind -ne 'process' -and $c.action -eq 'delete') {
            $ri = $rawByKey[[string]$r.key]
            if ($ri -and (Add-RgAgentKeep ([string]$ri.path) ([string]$r.reason) 'high')) { $autoKept = $true; $keptApplied++ }
        }
        $kept += [pscustomobject]@{ key = $r.key; verdict = $verdict; priority = [int][math]::Min(5, [math]::Max(1, [int]$r.priority)); confidence = $r.confidence; reason = $r.reason; autoKept = $autoKept }
    }
    $curCats = (Get-RgPolicy).categories
    $pol = @($so.policySuggestions | Where-Object { ($script:RgPolicyKinds -contains [string]$_.kind) -and ([string]$curCats[[string]$_.kind] -ne [string]$_.setting) })
    return [ordered]@{
        ok = $true; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); provider = $lr.provider; providerLabel = $lr.label; local = $lr.local; model = $lr.model; effort = $Effort
        costUsd = $lr.costUsd; durationMs = $lr.durationMs; payloadBytes = $lr.bytes
        result = [ordered]@{ summary = $so.summary; severity = $so.severity; findings = @($so.findings); recommendations = $kept; policySuggestions = $pol; droppedUnknownKeys = $dropped; keptApplied = $keptApplied }
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
    if ($Mode -eq 'clusters') {   # D3: verdict theo cụm; không đụng agent-last.json (kết quả đánh giá tổng quát)
        Set-Job 'running' ('đang hỏi ' + $($evp = Get-RgEvaluator; if ($evp) { $evp.label } else { 'trợ lý AI' }) + ' về các cụm tệp')
        $r = Invoke-RgClusterAgentEval -TimeoutSec $TimeoutSec -MaxBudgetUsd ([math]::Min($MaxBudgetUsd, 0.3)) -Model $Model -Effort 'medium'
        Write-RgLog 'agent-clusters' $r
        Set-Job 'done' $(if ($r.asked) { "xong: $($r.accepted)/$($r.asked) cụm" } else { [string]$r.message })
        return
    }
    Set-Job 'running' ('đang gọi ' + $($evp = Get-RgEvaluator; if ($evp) { $evp.label } else { 'trợ lý AI' }))
    $r = Invoke-RgAgentEval -TimeoutSec $TimeoutSec -MaxBudgetUsd $MaxBudgetUsd -Model $Model -Effort $Effort
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\agent-last.json') (ConvertTo-Json -InputObject $r -Depth 8 -Compress)
    Write-RgLog 'agent-eval' ([ordered]@{ ok = $true; costUsd = $r.costUsd; durationMs = $r.durationMs; payloadBytes = $r.payloadBytes; keptApplied = $r.result.keptApplied })
    Set-Job 'done' $(if ($null -ne $r.costUsd) { 'xong, chi phí $' + $r.costUsd } else { 'xong' })
}
catch {
    $msg = [string]$_.Exception.Message
    Write-RgLog 'agent-error' $msg
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\agent-last.json') (ConvertTo-Json -InputObject ([ordered]@{ ok = $false; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = $msg }) -Compress)
    Set-Job 'error' $msg
    exit 1
}
