# Ghi process do agent tạo ra vào ledger (khoá bằng PID + start time).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [string]$Agent = 'unknown',
    [string]$Label = '',
    [int]$OwnerPid = 0,
    [switch]$Heartbeat   # chỉ làm mới lastSeenUtc của mục đã đăng ký (agent còn sống), không đăng ký mới
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
if ($Heartbeat) { [pscustomobject]@{ pid = $ProcessId; heartbeat = (Update-RgLedgerHeartbeat -ProcId $ProcessId) } | ConvertTo-Json -Compress; return }
Register-RgProcess -ProcId $ProcessId -Agent $Agent -Label $Label -OwnerPid $OwnerPid | ConvertTo-Json -Depth 4
