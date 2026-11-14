# uninstall.ps1 - gỡ Resource Guard của người dùng hiện tại.
#   uninstall.ps1               # dừng app, gỡ tác vụ tự chạy, lối tắt, PATH, mục Settings > Apps, thư mục cài. GIỮ dữ liệu (~/.agent-resource).
#   uninstall.ps1 -PurgeData    # xoá luôn dữ liệu: chính sách, PIN, nhật ký, lịch sử số đo, biên lai dọn.
#   uninstall.ps1 -Quiet        # không hỏi lại (dùng trong script)
# Không bao giờ đụng tới file nào Resource Guard từng dọn hay giữ lại: chỉ xoá những gì trình cài đã tạo.
[CmdletBinding()]
param([switch]$PurgeData, [switch]$Quiet, [string]$Dest = '')
$ErrorActionPreference = 'Stop'
$uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResourceGuard'
if (-not $Dest) {
    try { $Dest = [string](Get-ItemProperty -LiteralPath $uk -ErrorAction Stop).InstallLocation } catch { }
    if (-not $Dest) { $Dest = $PSScriptRoot }
}
$Dest = [IO.Path]::GetFullPath($Dest)
$isInstall = Test-Path -LiteralPath (Join-Path $Dest 'rg.ps1')
$isRepo = Test-Path -LiteralPath (Join-Path $Dest '.git')
$home2 = if ($env:AGENT_RESOURCE_HOME) { $env:AGENT_RESOURCE_HOME } else { Join-Path $HOME '.agent-resource' }

if (-not $Quiet) {
    Write-Host ("Gỡ Resource Guard ở $Dest" + $(if ($PurgeData) { " VÀ xoá dữ liệu ở $home2" } else { " (giữ dữ liệu ở $home2)" }))
    $a = Read-Host 'Tiếp tục? (y/N)'
    if ($a -notmatch '^(y|yes|c|co|có)$') { 'Đã huỷ.'; return }
}

# 1. Dừng app nếu đang chạy.
$info = Join-Path $home2 'state\server.json'
if (Test-Path -LiteralPath $info) {
    try {
        $i = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($i -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue)) {
            try { Invoke-RestMethod -Method Post -Uri ($i.url + 'api/shutdown') -Headers @{ 'X-RG-Client' = 'ui' } -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null } catch { }
            for ($k = 0; $k -lt 40 -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue); $k++) { Start-Sleep -Milliseconds 250 }
            if (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue) { Stop-Process -Id ([int]$i.pid) -Force -ErrorAction SilentlyContinue }
            'Đã dừng Resource Guard.'
        }
    } catch { }
}

# 2. Tác vụ tự chạy + lối tắt.
try { Stop-ScheduledTask -TaskName 'ResourceGuardWatcher' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'ResourceGuardWatcher' -Confirm:$false -ErrorAction Stop; 'Đã gỡ tác vụ tự chạy.' } catch { }
foreach ($l in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Resource Guard.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Resource Guard.lnk'))) {
    if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; "Đã xoá lối tắt $l" }
}

# 3. PATH người dùng.
$cur = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($cur) {
    $parts = @($cur -split ';' | Where-Object { $_ })
    $keep = @($parts | Where-Object { $_.TrimEnd('\') -ine $Dest.TrimEnd('\') })
    if ($keep.Count -ne $parts.Count) { [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), 'User'); 'Đã gỡ khỏi PATH người dùng.' }
}

# 4. Mục Settings > Apps.
if (Test-Path -LiteralPath $uk) { Remove-Item -LiteralPath $uk -Recurse -Force; 'Đã gỡ khỏi Settings > Apps.' }

# 5. Thư mục cài. Không bao giờ xoá một bản git clone (người dùng đang phát triển ở đó).
Set-Location -LiteralPath $env:TEMP
if ($isInstall -and -not $isRepo) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $Dest) { "Còn sót một số file ở $Dest (đang bị khoá); xoá tay sau khi khởi động lại." } else { "Đã xoá $Dest" } }
elseif ($isRepo) { "Bỏ qua thư mục $Dest vì đó là bản git clone." }

# 6. Dữ liệu (chỉ khi được yêu cầu).
if ($PurgeData) {
    if (Test-Path -LiteralPath $home2) { Remove-Item -LiteralPath $home2 -Recurse -Force; "Đã xoá dữ liệu $home2" }
} else { "Dữ liệu giữ ở $home2 (cài lại sẽ dùng tiếp; xoá hẳn: uninstall.ps1 -PurgeData)." }
'Đã gỡ Resource Guard.'
