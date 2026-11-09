# rg-restore.ps1 - giải nén một bản zip do tool tạo về đúng vị trí cũ (job nền; tiến độ ghi vào cleanup.progress.json như lượt dọn).
#   Chỉ nhận id (12 hex) trong state\archives.json. Không ghi đè dữ liệu có sẵn; chống zip-slip.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Id)
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
    if ($Id -notmatch '^[0-9a-f]{12}$') { throw 'Id không hợp lệ.' }
    Set-Job 'running' 'đang giải nén…'
    $rec = Restore-RgArchive $Id
    Set-Job 'done' ("đã khôi phục {0} ({1:n1} MB)" -f $rec.original, ([double]$rec.bytes / 1MB))
}
catch {
    Write-RgLog 'cleanup-error' ([string]$_)
    Set-Job 'error' ([string]$_.Exception.Message)
    exit 1
}
