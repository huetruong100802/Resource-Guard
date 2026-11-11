# rg.ps1 - lệnh duy nhất để chạy/dừng Resource Guard (gọn hơn resource-manager.ps1 serve ...).
#   rg start                 # chạy ngầm (nếu chưa chạy) và mở giao diện; đã chạy thì chỉ mở lại trình duyệt
#   rg stop [-Force]         # dừng êm; từ chối nếu đang dọn dở. -Force: buộc dừng
#   rg restart               # dừng rồi chạy lại
#   rg status                # đang chạy/không, URL, chế độ tự dọn, tự chạy cùng Windows, lối tắt
#   rg run                   # chạy ở cửa sổ này (Ctrl+C để dừng), không chạy ngầm
#   rg autostart on|off      # tự chạy ngầm mỗi lần đăng nhập Windows
#   rg shortcut [remove]     # lối tắt "Resource Guard" ở Start Menu (thêm -Desktop để tạo cả ngoài màn hình nền)
#   rg path [remove]         # thêm thư mục này vào PATH của người dùng để gõ "rg" ở bất kỳ đâu (mở terminal mới sau khi thêm)
#   rg pin                   # đặt PIN cho chế độ tự dọn "Bật" (chỉ ở console tương tác)
#   rg hooks print [-Heavy]  # IN đoạn JSON hook cho ~/.claude/settings.json (không tự sửa file); -Heavy thêm build/test qua Bash. rg hooks status: lease đang giữ
#   rg panic                 # DỪNG KHẨN CẤP: tắt chính sách tự động + huỷ mọi job nền của Resource Guard (không cần PIN; bật lại cần PIN)
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('start', 'open', 'stop', 'restart', 'status', 'run', 'autostart', 'shortcut', 'path', 'pin', 'hooks', 'panic', 'help')][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Arg = '',
    [int]$Port = 8765, [switch]$Force, [switch]$NoOpen, [switch]$Desktop, [switch]$Heavy
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$srv = Join-Path $root 'scripts\rg-server.ps1'
$taskName = 'ResourceGuardWatcher'
$lnkName = 'Resource Guard.lnk'

function Get-RgHomeDir { if ($env:AGENT_RESOURCE_HOME) { $env:AGENT_RESOURCE_HOME } else { Join-Path $HOME '.agent-resource' } }
function Get-LiveInfo {
    $p = Join-Path (Get-RgHomeDir) 'state\server.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $i = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($i -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue)) { return $i }
    return $null
}
. (Join-Path $root 'scripts\rg-setup.ps1')   # Set-RgAutostart / Set-RgShortcut: dùng chung với POST /api/setup
function Get-LnkPaths { Get-RgLnkPaths }
function Get-PolicyMode {
    $p = Join-Path (Get-RgHomeDir) 'state\policy.json'
    if (Test-Path -LiteralPath $p) { try { return [string](Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).mode } catch { } }
    return 'off'
}
function Test-TaskInstalled { Test-RgTaskInstalled }
function Test-ShortcutExists { Test-RgShortcutExists }

switch ($Command) {
    { $_ -in 'start', 'open' } {
        & $srv -Port $Port -Detach -NoOpen:$NoOpen
        if (-not (Test-ShortcutExists)) { 'Mẹo: chạy ".\rg.ps1 shortcut" để có lối tắt "Resource Guard" ở Start Menu, lần sau chỉ cần bấm.' }
    }
    'stop' { & $srv -Stop -Force:$Force }
    'restart' {
        & $srv -Stop -Force:$Force
        if (Get-LiveInfo) { return }   # chưa dừng được (đang dọn dở) thì không chạy lại
        & $srv -Port $Port -Detach -NoOpen:$NoOpen
    }
    'run' { & $srv -Port $Port -NoOpen:$NoOpen }
    'status' {
        $i = Get-LiveInfo
        if ($i) {
            $up = [datetime]::UtcNow - [datetime]::Parse([string]$i.startedUtc, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
            "Trạng thái   : ĐANG CHẠY (pid $($i.pid), đã chạy $([math]::Floor($up.TotalHours))h$($up.Minutes)p)"
            "Giao diện    : $($i.url)"
        } else { 'Trạng thái   : ĐANG DỪNG   (chạy: rg start)' }
        "Tự dọn       : $(Get-PolicyMode)  (chỉ hoạt động khi app đang chạy)"
        "Tự chạy cùng Windows : $(if (Test-TaskInstalled) { 'bật' } else { 'tắt  (bật: rg autostart on)' })"
        "Lối tắt Start Menu   : $(if (Test-ShortcutExists) { 'có' } else { 'chưa có  (tạo: rg shortcut)' })"
    }
    'autostart' {
        switch ($Arg) {
            'on' { Set-RgAutostart $true $root }
            'off' { Set-RgAutostart $false $root }
            default { 'Dùng: rg autostart on | off' }
        }
    }
    'shortcut' {
        if ($Arg -eq 'remove') { Set-RgShortcut $false $root; return }
        Set-RgShortcut $true $root -Desktop:$Desktop
    }
    'path' {
        $cur = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $cur) { $cur = '' }
        $parts = @($cur -split ';' | Where-Object { $_ })
        $has = [bool]($parts | Where-Object { $_.TrimEnd('\') -ieq $root.TrimEnd('\') })
        if ($Arg -eq 'remove') {
            if ($has) { [Environment]::SetEnvironmentVariable('Path', (($parts | Where-Object { $_.TrimEnd('\') -ine $root.TrimEnd('\') }) -join ';'), 'User'); "Đã gỡ $root khỏi PATH người dùng." }
            else { 'PATH người dùng không chứa thư mục này.' }
            return
        }
        if ($has) { 'Đã có trong PATH người dùng.'; return }
        [Environment]::SetEnvironmentVariable('Path', (($parts + $root) -join ';'), 'User')
        "Đã thêm $root vào PATH người dùng. Mở terminal mới rồi gõ: rg status"
    }
    'pin' { & (Join-Path $root 'scripts\resource-manager.ps1') serve setpin }
    'hooks' {
        . (Join-Path $root 'scripts\rg-common.ps1')
        switch ($Arg) {
            'print' {
                # stdout chỉ có JSON (để chuyển hướng/ghép); lời nhắc đi qua Write-Host. Resource Guard KHÔNG bao giờ tự sửa settings của bạn.
                [Console]::Error.WriteLine('Gộp khối "hooks" dưới đây vào ~/.claude/settings.json (hoặc .claude/settings.json của dự án). Resource Guard không tự sửa file này.')
                Get-RgHooksSnippet $root -Heavy:$Heavy
            }
            'status' {
                $ls = @(Get-RgLeases)
                if ($ls.Count) { $ls | Format-Table sessionId, agent, token, subagents, reservations, lastSeenUtc -AutoSize | Out-String } else { 'Không có phiên agent nào đang giữ lease.' }
            }
            default { 'Dùng: rg hooks print [-Heavy] | rg hooks status' }
        }
    }
    'panic' {
        . (Join-Path $root 'scripts\rg-common.ps1'); . (Join-Path $root 'scripts\rg-policy.ps1')
        $pr = Invoke-RgPanic -By 'cli'
        "Đã dừng khẩn cấp: chính sách tự động trước đó '$($pr.modeBefore)' -> 'off'; huỷ $(@($pr.stopped).Count) job nền" + $(if (@($pr.failed).Count) { "; $(@($pr.failed).Count) việc không dừng được (xem logs)" } else { '' }) + '. Bật lại ở màn Chính sách (cần PIN).'
    }
    default {
        Get-Content -LiteralPath $PSCommandPath -TotalCount 13 -Encoding UTF8 | ForEach-Object { $_ -replace '^#   ?', '  ' -replace '^# ', '' }
    }
}
