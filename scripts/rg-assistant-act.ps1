# rg-assistant-act.ps1 - thi hành MỘT hành động của người dùng trên MỘT cụm trong "Báo cáo của trợ lý" (D5). Chạy ở process riêng.
#   -ClusterId <12 hex> -Action compress|clean [-By ui]
# UI chỉ gửi clusterId + hành động. Việc giải đường dẫn và kiểm tra nằm trong Invoke-RgClusterAction (rg-assistant.ps1):
#   mỗi file vẫn đi qua plan -> approve -> Invoke-RgApply (allowlist 'cluster-file' + revalidate từng file + vùng bảo vệ + kiểm file đang được dùng + journal).
#   compress: nén zip CÓ XÁC MINH cạnh từng file rồi mới xoá bản gốc (khôi phục được ở "Bản đã nén").
#   clean   : xoá thẳng, chỉ cho họ file không phải của cá nhân (bộ cài, file tạm). File cá nhân tối đa là nén.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ClusterId, [Parameter(Mandatory)][ValidateSet('compress', 'clean')][string]$Action, [string]$By = 'ui')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
$jobFile = 'cleanup.progress.json'; $started = (Get-Date).ToUniversalTime().ToString('o')
function Set-Job([string]$Status, [string]$Msg = '') {
    Write-RgJobState $jobFile ([ordered]@{ pid = $PID; status = $Status; message = $Msg; startedUtc = $started; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
}
try {
    $cur = Get-RgJobState $jobFile
    if ($cur -and $cur.status -eq 'running' -and [int]$cur.pid -ne $PID) { return }
    if ($ClusterId -notmatch '^[0-9a-f]{12}$') { throw 'clusterId không hợp lệ.' }
    Set-Job 'running' 'đang chuẩn bị'
    Set-Job 'running' 'đang xử lý cụm'
    # E1: đi qua cửa duy nhất (kiểm schema + mức nhóm) rồi mới tới Invoke-RgClusterAction; compress = archive-cluster, clean = clean-cluster
    $ar = Invoke-RgAction -Id $(if ($Action -eq 'compress') { 'archive-cluster' } else { 'clean-cluster' }) -Params @{ clusterId = $ClusterId } -Actor human -By "$By`:$env:USERNAME"
    if (-not $ar.result) { throw $ar.reason }   # bị chặn trước khi chạy (nhóm tắt, tham số sai) hoặc backend từ chối: giữ nguyên lý do tiếng Việt
    $rec = $ar.result
    if ($rec.done -gt 0) {   # cập nhật báo cáo để cụm vừa xử lý không còn hiện như cũ; lỗi ở bước này không làm hỏng kết quả dọn
        try { Set-Job 'running' 'đang cập nhật báo cáo'; [void](Invoke-RgAssistantScan (Get-RgConfig)) } catch { Write-RgLog 'assistant-rescan-error' ([string]$_) }
    }
    Set-Job 'done' ("{0} tệp đã xử lý, {1:n1} MB giải phóng" -f $rec.done, ($rec.freedBytes / 1MB))
}
catch {
    Write-RgLog 'assistant-act-error' ([string]$_)
    Set-Job 'error' ([string]$_.Exception.Message)
    exit 1
}
