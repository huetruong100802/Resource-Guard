# rg-elevated-clean.ps1 - CHẠY TRONG TIẾN TRÌNH ELEVATED, do rg-elevate.ps1 bật sau khi người dùng xác nhận UAC.
#   Chỉ gọi Invoke-RgElevatedClean (kiểm tra độc lập từng mục: thư mục GUID trực tiếp dưới %TEMP%, đủ tuổi, không junction...).
#   Không nhận đường dẫn, chỉ nhận key. Không tự nâng quyền; không phải admin thì thoát.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Keys, [Parameter(Mandatory)][string]$HomeDir)
$ErrorActionPreference = 'Stop'
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { exit 3 }
if (-not [IO.Path]::IsPathRooted($HomeDir) -or -not (Test-Path -LiteralPath $HomeDir -PathType Container)) { exit 4 }
$env:AGENT_RESOURCE_HOME = $HomeDir
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
try {
    [void](Invoke-RgElevatedClean -Keys @($Keys.Split(',')) -By 'ui-elevated')
    exit 0
} catch {
    Write-RgLog 'cleanup-error' ('elevated: ' + [string]$_)
    exit 1
}
