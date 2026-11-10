# rg-setup.ps1 - "tự chạy cùng Windows" và lối tắt Start Menu. Dùng chung cho `rg autostart|shortcut` (rg.ps1) và POST /api/setup
# nên hai đường luôn làm đúng một việc. Độc lập: KHÔNG phụ thuộc rg-common.ps1 (rg.ps1 không nạp nó). Không cần quyền admin.
# $Root = thư mục gốc của repo (nơi có rg.ps1 và scripts\).

$script:RgTaskName = 'ResourceGuardWatcher'
$script:RgLnkName = 'Resource Guard.lnk'

function Get-RgLnkPaths {
    return @((Join-Path ([Environment]::GetFolderPath('Programs')) $script:RgLnkName), (Join-Path ([Environment]::GetFolderPath('Desktop')) $script:RgLnkName))
}
function Test-RgTaskInstalled {
    try { return [bool](Get-ScheduledTask -TaskName $script:RgTaskName -ErrorAction SilentlyContinue) } catch { return $false }
}
function Test-RgShortcutExists { return [bool](Get-RgLnkPaths | Where-Object { Test-Path -LiteralPath $_ }) }

# Bật/tắt tự chạy cùng Windows (Scheduled Task, quyền user thường). $NoStart: đăng ký nhưng không chạy ngay (dùng khi server đang chạy).
function Set-RgAutostart([bool]$On, [string]$Root, [switch]$NoStart) {
    $inst = Join-Path $Root 'scripts\Install-Watcher.ps1'
    if (-not (Test-Path -LiteralPath $inst)) { throw 'Không tìm thấy scripts\Install-Watcher.ps1.' }
    if ($On) { return @(& $inst -NoStart:$NoStart) }
    return @(& $inst -Uninstall)
}

# Tạo/xoá lối tắt Start Menu (-Desktop: thêm ngoài màn hình nền khi tạo; khi xoá thì xoá cả hai).
function Set-RgShortcut([bool]$On, [string]$Root, [switch]$Desktop) {
    $out = @()
    if (-not $On) {
        foreach ($p in (Get-RgLnkPaths)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $out += "Đã xoá $p" } }
        return $out
    }
    $targets = @(Join-Path ([Environment]::GetFolderPath('Programs')) $script:RgLnkName)
    if ($Desktop) { $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) $script:RgLnkName }
    $sh = New-Object -ComObject WScript.Shell
    foreach ($t in $targets) {
        $l = $sh.CreateShortcut($t)
        $l.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $l.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" start' -f (Join-Path $Root 'rg.ps1')
        $l.WorkingDirectory = $Root
        $l.WindowStyle = 7
        $l.Description = 'Mở Resource Guard (chạy ngầm nếu chưa chạy)'
        $l.Save()
        $out += "Đã tạo lối tắt: $t"
    }
    return $out
}
