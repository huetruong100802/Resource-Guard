# Tạo cleanup plan (chỉ đọc + ghi file plan; KHÔNG xoá/kill). -ScanOnly: chỉ liệt kê, không lưu plan.
[CmdletBinding()]
param([switch]$ScanOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

$items = @(Get-RgCandidates)
if ($ScanOnly) {
    $items | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Json -Depth 5
} else {
    New-RgPlan -Items $items | ConvertTo-Json -Depth 8
}
