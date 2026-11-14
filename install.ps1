# install.ps1 - cài Resource Guard cho người dùng hiện tại (không cần quyền admin).
#   powershell -ExecutionPolicy Bypass -File install.ps1                  # cài vào %LOCALAPPDATA%\Programs\ResourceGuard, tạo lối tắt Start Menu, mở app
#   install.ps1 -Autostart -Desktop -AddToPath                              # thêm: chạy cùng Windows, lối tắt màn hình nền, lệnh `rguard` trong PATH
#   install.ps1 -Dest D:\Apps\ResourceGuard -NoStart                         # thư mục khác, không mở app sau khi cài
# Cài lại/cập nhật: chạy lại lệnh này (dữ liệu trong ~/.agent-resource được giữ nguyên). Gỡ: uninstall.ps1 hoặc Settings > Apps.
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:LOCALAPPDATA 'Programs\ResourceGuard'),
    [switch]$Autostart, [switch]$Desktop, [switch]$AddToPath, [switch]$NoStart, [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Cần Windows PowerShell 5.1 trở lên.' }
$ver = try { ([IO.File]::ReadAllText((Join-Path $src 'VERSION'))).Trim() } catch { '0.0.0-dev' }
$Dest = [IO.Path]::GetFullPath($Dest)
if ($Dest.TrimEnd('\') -ieq $src.TrimEnd('\')) { throw 'Thư mục cài trùng thư mục nguồn. Chạy install.ps1 từ bản tải về, hoặc chọn -Dest khác.' }

"Cài Resource Guard $ver vào $Dest"

# 1. Dừng bản đang chạy (nếu có) để chép đè được file. Dữ liệu không bị đụng.
$home2 = if ($env:AGENT_RESOURCE_HOME) { $env:AGENT_RESOURCE_HOME } else { Join-Path $HOME '.agent-resource' }
$info = Join-Path $home2 'state\server.json'
if (Test-Path -LiteralPath $info) {
    try {
        $i = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($i -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue)) {
            '  Dừng Resource Guard đang chạy…'
            try { Invoke-RestMethod -Method Post -Uri ($i.url + 'api/shutdown') -Headers @{ 'X-RG-Client' = 'ui' } -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null } catch { }
            for ($k = 0; $k -lt 40 -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue); $k++) { Start-Sleep -Milliseconds 250 }
            if (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue) { Stop-Process -Id ([int]$i.pid) -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

# 2. Chép file của ứng dụng (chỉ những gì cần để chạy). Thư mục cài được làm mới hoàn toàn để không sót file của bản cũ.
$items = @('rg.ps1', 'rg.cmd', 'rguard.cmd', 'install.ps1', 'uninstall.ps1', 'VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md', 'config.default.json', 'scripts', 'ui')
if (Test-Path -LiteralPath $Dest) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dest 'rg.ps1'))) {
        if (@(Get-ChildItem -LiteralPath $Dest -Force).Count) { throw "Thư mục $Dest đã có nội dung không phải Resource Guard; chọn -Dest khác." }
    } else {
        foreach ($n in $items) { $p = Join-Path $Dest $n; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    }
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($n in $items) {
    $p = Join-Path $src $n
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $Dest -Recurse -Force }
}
# Cấu hình của người dùng (config.json), chính sách, PIN, nhật ký nằm trong ~/.agent-resource, không nằm ở thư mục cài: cập nhật không mất gì.
'  Đã chép file.'

# 3. Lối tắt, tự chạy, PATH. Tất cả ở phạm vi người dùng.
. (Join-Path $Dest 'scripts\rg-setup.ps1')
if (-not $NoShortcut) { Set-RgShortcut $true $Dest -Desktop:$Desktop | ForEach-Object { "  $_" } }
if ($Autostart) { Set-RgAutostart $true $Dest -NoStart | ForEach-Object { "  $_" } }
elseif (Test-RgTaskInstalled) { Set-RgAutostart $true $Dest -NoStart | Out-Null; '  Đã trỏ tác vụ tự chạy sang bản mới.' }
if ($AddToPath) {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $cur) { $cur = '' }
    $parts = @($cur -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Dest.TrimEnd('\') })
    [Environment]::SetEnvironmentVariable('Path', (($parts + $Dest) -join ';'), 'User')
    '  Đã thêm vào PATH người dùng: mở terminal mới rồi gõ "rguard status".'
}

# 4. Mục trong Settings > Apps (HKCU, không cần admin) để gỡ như ứng dụng thường.
$uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResourceGuard'
New-Item -Path $uk -Force | Out-Null
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$size = [int]((Get-ChildItem -LiteralPath $Dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
$vals = [ordered]@{ DisplayName = 'Resource Guard'; DisplayVersion = $ver; Publisher = 'Resource Guard'; InstallLocation = $Dest
    UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest 'uninstall.ps1')`""
    DisplayIcon = "$ps,0"; InstallDate = (Get-Date -Format 'yyyyMMdd') }
foreach ($k in $vals.Keys) { Set-ItemProperty -Path $uk -Name $k -Value $vals[$k] }
Set-ItemProperty -Path $uk -Name EstimatedSize -Value $size -Type DWord
Set-ItemProperty -Path $uk -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uk -Name NoRepair -Value 1 -Type DWord
'  Đã đăng ký trong Settings > Apps.'

"Xong. Resource Guard $ver đã cài."
if (-not $NoStart) { & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'rg.ps1') start }
