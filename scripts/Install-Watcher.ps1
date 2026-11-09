# Đăng ký watcher chạy ngầm khi đăng nhập (Scheduled Task, quyền user thường, không cần admin).
#   Install-Watcher.ps1            # cài + chạy ngay
#   Install-Watcher.ps1 -Uninstall # gỡ task (state/log giữ nguyên)
[CmdletBinding()]
param([switch]$Uninstall, [switch]$NoStart)
$ErrorActionPreference = 'Stop'
$name = 'ResourceGuardWatcher'
$script = Join-Path $PSScriptRoot 'rg-server.ps1'   # watcher + UI localhost (cùng mutex, chỉ một bản chạy)

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    'Đã gỡ task ResourceGuardWatcher.'
    return
}

# powershell.exe (5.1) để toast WinRT hoạt động; chạy ẩn, quyền user thường, ưu tiên thấp do chính script đặt.
$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -NoOpen' -f $script
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
if (-not $NoStart) { Start-ScheduledTask -TaskName $name }
"Đã cài task '$name' (chế độ GIÁM SÁT). Trang trạng thái: " + (Join-Path ($(if ($env:AGENT_RESOURCE_HOME) { $env:AGENT_RESOURCE_HOME } else { Join-Path $HOME '.agent-resource' })) 'state\status.html')
