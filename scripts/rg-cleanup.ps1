# rg-cleanup.ps1 - dọn các mục NGƯỜI DÙNG đã chọn trên UI (theo key trong state\scan-candidates.json). Chạy ở process riêng.
#   Chỉ nhận key (12 hex), không nhận đường dẫn từ client. Vẫn đi qua plan -> approve -> Invoke-RgApply (allowlist + revalidate).
#   Mục nằm trong vùng bảo vệ của chính sách bị từ chối kể cả khi người dùng chọn.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Keys, [string]$By = 'ui', [switch]$Archive)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
$jobFile = 'cleanup.progress.json'; $started = (Get-Date).ToUniversalTime().ToString('o')
function Set-Job([string]$Status, [string]$Msg = '') {
    Write-RgJobState $jobFile ([ordered]@{ pid = $PID; status = $Status; message = $Msg; startedUtc = $started; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
}
$statePath = Join-Path (Initialize-RgHome) 'state'
try {
    $cur = Get-RgJobState $jobFile
    if ($cur -and $cur.status -eq 'running' -and [int]$cur.pid -ne $PID) { return }
    Set-Job 'running' 'đang chuẩn bị'
    $want = @($Keys.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
    if ($want.Count -eq 0) { throw 'Không có key hợp lệ.' }
    $cf = Join-Path $statePath 'scan-candidates.json'
    if (-not (Test-Path -LiteralPath $cf)) { throw 'Chưa có danh sách ứng viên; hãy quét trước.' }
    $cd = ConvertFrom-Json (Read-RgFileShared $cf)
    if (Test-RgScanStale ([string]$cd.finishedUtc)) { throw 'Dữ liệu quét đã cũ hơn 12 giờ; hãy quét lại trước khi dọn.' }
    $policy = Get-RgPolicy
    $items = @(); $refused = @()
    foreach ($k in $want) {
        $c = @($cd.items | Where-Object { $_.key -eq $k }) | Select-Object -First 1
        if (-not $c) { $refused += [pscustomobject]@{ key = $k; reason = 'không còn trong danh sách ứng viên' }; continue }
        if ($c.action -eq 'report') { $refused += [pscustomobject]@{ key = $k; reason = 'mục chỉ báo cáo, không được xoá' }; continue }
        $prot = if ($c.kind -eq 'process') { Test-RgProcessProtected ([string]$c.name) $policy } else { Test-RgPathProtected ([string]$c.path) $policy }
        if ($prot) { $refused += [pscustomobject]@{ key = $k; reason = 'nằm trong vùng bảo vệ' }; continue }
        $items += New-RgItem -Kind ([string]$c.kind) -Action ([string]$c.action) -Level ([int]$c.level) -Path ([string]$c.path) -ProcId ([int]$c.pid) -Start ([string]$c.start) `
            -Name ([string]$c.name) -SizeBytes ([long]$c.sizeBytes) -NewestUtc ([string]$c.newestWriteUtc) -Reason ([string]$c.reason) -Risk ([string]$c.risk) -AgeDays ([int]$c.ageDays) `
            -Archive ([bool]($Archive -and (Test-RgArchivable ([string]$c.kind)))) -Young ([bool]$c.young)
    }
    $results = @(); $freed = 0L; $planId = $null
    if ($items.Count -gt 0) {
        Set-Job 'running' "đang dọn $($items.Count) mục"
        $plan = New-RgPlan -Items $items
        $planId = $plan.planId
        $ids = @($plan.items | Where-Object { $_.action -ne 'report' } | ForEach-Object { [int]$_.id })
        [void](Set-RgPlanApproval -PlanId $planId -ItemIds $ids -By "$By`:$env:USERNAME")
        $res = Invoke-RgApply -PlanId $planId
        $freed = [long]$res.freedBytes
        # đối chiếu key theo (kind, target) để UI biết mục nào đã xong
        $keyOf = @{}; foreach ($c in @($cd.items)) { $t = if ($c.kind -eq 'process') { "pid $($c.pid) $($c.name)" } else { [string]$c.path }; $keyOf["$($c.kind)|$t"] = $c.key }
        $results = @($res.results | ForEach-Object { [pscustomobject]@{ key = $keyOf["$($_.kind)|$($_.target)"]; kind = $_.kind; target = $_.target; outcome = $_.outcome; detail = $_.detail } })
        $doneKeys = @($results | Where-Object { $_.outcome -eq 'done' } | ForEach-Object { $_.key })
        if ($doneKeys.Count -gt 0) {   # bỏ mục đã xoá khỏi danh sách ứng viên để UI không hiện lại
            $cd.items = @($cd.items | Where-Object { $doneKeys -notcontains $_.key })
            Write-RgFileAtomic $cf (ConvertTo-Json -InputObject $cd -Depth 8 -Compress)
        }
    }
    $rec = [ordered]@{ finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); by = $By; planId = $planId; freedBytes = $freed; results = $results; refused = $refused }
    Write-RgFileAtomic (Join-Path $statePath 'cleanup-last.json') (ConvertTo-Json -InputObject $rec -Depth 6 -Compress)
    Write-RgLog 'manual-cleanup' ([ordered]@{ by = $By; planId = $planId; items = $results.Count; refused = $refused.Count; freedBytes = $freed })
    Set-Job 'done' ("{0:n1} MB giải phóng, {1} mục bị từ chối" -f ($freed / 1MB), $refused.Count)
}
catch {
    Write-RgLog 'cleanup-error' ([string]$_)
    Set-Job 'error' ([string]$_.Exception.Message)
    exit 1
}
