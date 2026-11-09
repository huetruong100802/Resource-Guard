# Thực thi plan ĐÃ ĐƯỢC DUYỆT. Revalidate từng item ngay trước khi xoá/kill. Exit: 0 ok, 1 có item lỗi, 4 chưa duyệt, 5 plan bị đổi, 6 đã apply.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanId, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

$r = Invoke-RgApply -PlanId $PlanId -DryRun:$DryRun
$r | ConvertTo-Json -Depth 6
if ($r.code -ne 0) { exit $r.code }
if (-not $r.ok) { exit 1 }
exit 0
