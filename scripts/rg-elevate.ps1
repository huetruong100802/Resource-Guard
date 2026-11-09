# rg-elevate.ps1 - job nền (quyền thường): bật UAC để chạy rg-elevated-clean.ps1 cho các mục "cần quyền admin" người dùng đã xác nhận.
#   Tiến độ ghi vào cleanup.progress.json (UI dùng chung với lượt dọn thường). Người dùng từ chối UAC => không xoá gì.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Keys)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
$jobFile = 'cleanup.progress.json'; $started = (Get-Date).ToUniversalTime()
function Set-Job([string]$Status, [string]$Msg = '') {
    Write-RgJobState $jobFile ([ordered]@{ pid = $PID; status = $Status; message = $Msg; startedUtc = $started.ToString('o'); updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
}
try {
    $cur = Get-RgJobState $jobFile
    if ($cur -and $cur.status -eq 'running' -and [int]$cur.pid -ne $PID) { return }
    $want = @($Keys.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
    if ($want.Count -eq 0) { throw 'Không có key hợp lệ.' }
    Set-Job 'running' 'chờ bạn xác nhận hộp thoại UAC của Windows…'
    $exe = (Get-Process -Id $PID).Path
    $script = Join-Path $PSScriptRoot 'rg-elevated-clean.ps1'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-Keys', ($want -join ','), '-HomeDir', ('"' + (Initialize-RgHome).TrimEnd('\') + '"'))
    Write-RgLog 'elevate-request' ([ordered]@{ items = $want.Count })
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argv -Verb RunAs -WindowStyle Hidden -PassThru
    } catch {
        $ne = 0; if ($_.Exception -is [ComponentModel.Win32Exception]) { $ne = $_.Exception.NativeErrorCode }
        if ($ne -eq 1223) { Write-RgLog 'elevate-declined' @{}; Set-Job 'error' 'Bạn đã từ chối UAC; không có gì bị xoá.'; return }
        throw
    }
    Set-Job 'running' 'đang dọn bằng quyền admin…'
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Tiến trình admin kết thúc với mã $($p.ExitCode); xem logs\rg-*.jsonl." }
    $last = $null; try { $last = ConvertFrom-Json (Read-RgFileShared (Join-Path (Initialize-RgHome) 'state\cleanup-last.json')) } catch { }
    if (-not $last -or [datetime]::Parse([string]$last.finishedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime() -lt $started) { throw 'Tiến trình admin không ghi kết quả.' }
    $ok = @($last.results | Where-Object { $_.outcome -eq 'done' }).Count
    Set-Job 'done' ('{0:n1} MB giải phóng (quyền admin), {1}/{2} mục xong' -f ([double]$last.freedBytes / 1MB), $ok, @($last.results).Count)
}
catch {
    Write-RgLog 'cleanup-error' ([string]$_)
    Set-Job 'error' ([string]$_.Exception.Message)
    exit 1
}
