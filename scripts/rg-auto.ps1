# rg-auto.ps1 - một lượt tự dọn theo chính sách, chạy ở process riêng (server không bị chặn khi máy lag).
#   (mặc định) chỉ chạy khi mode != off và có áp lực; mode 'on' mới xoá thật, 'dry-run' chỉ ghi nhận.
#   -Force   : bỏ qua kiểm tra áp lực/cooldown (nút "Chạy thử" trên UI); luôn dry-run trừ khi mode = on VÀ không có -DryRun
#   -DryRun  : ép mô phỏng
[CmdletBinding()]
param([switch]$Force, [switch]$DryRun, [string]$Trigger = 'auto')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
$jobFile = 'auto.progress.json'
$started = (Get-Date).ToUniversalTime().ToString('o')
function Set-Job([string]$Status, [string]$Msg = '') {
    Write-RgJobState $jobFile ([ordered]@{ pid = $PID; status = $Status; message = $Msg; startedUtc = $started; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
}
try {
    $cur = Get-RgJobState $jobFile
    if ($cur -and $cur.status -eq 'running' -and [int]$cur.pid -ne $PID) { return }   # đã có lượt khác đang chạy
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
    $policy = Get-RgPolicy
    if ([string]$policy.mode -eq 'off' -and -not $Force) { return }
    Set-Job 'running' 'đang quét ứng viên'
    $cfg = Get-RgConfig
    $stress = Get-RgStressInfo $policy $cfg (Get-RgSnapshot -SkipCpu)
    if (-not $Force -and -not ($stress.diskStress -or $stress.ramStress)) { Set-Job 'done' 'không có áp lực'; return }
    $cands = @(Get-RgCandidates)
    $real = ([string]$policy.mode -eq 'on') -and -not $DryRun
    $rec = Invoke-RgAutoRun -Candidates $cands -Policy $policy -Real $real -Trigger $Trigger -AssumeStress ([bool]($Force -and -not $real))
    Set-Job 'done' ("{0} mục, giải phóng {1:n1} MB" -f @($rec.items).Count, ($rec.freedBytes / 1MB))
}
catch {
    Write-RgLog 'auto-error' ([string]$_)
    Set-Job 'error' ([string]$_.Exception.Message)
    exit 1
}
