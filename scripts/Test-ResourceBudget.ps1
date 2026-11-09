# Preflight: in JSON quyết định. Exit code 0 = allow/warn, 2 = deny.
# Mặc định chỉ tư vấn; hook (P2) phải tự map exit code/JSON theo giao thức của từng CLI trước khi bật chặn.
[CmdletBinding()]
param([ValidateSet('build', 'test', 'subagent', 'session')][string]$Task = 'session')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

$b = Get-RgBudget -Task $Task
Write-RgLog 'preflight' $b
$b | ConvertTo-Json -Depth 5
if ($b.decision -eq 'deny') { exit 2 }
exit 0
