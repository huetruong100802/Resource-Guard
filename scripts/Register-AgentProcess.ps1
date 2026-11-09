# Ghi process do agent tạo ra vào ledger (khoá bằng PID + start time).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [string]$Agent = 'unknown',
    [string]$Label = '',
    [int]$OwnerPid = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
Register-RgProcess -ProcId $ProcessId -Agent $Agent -Label $Label -OwnerPid $OwnerPid | ConvertTo-Json -Depth 4
