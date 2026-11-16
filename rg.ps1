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
#   rg connect [agent]       # cách kết nối một agent (claude, codex, gemini, cursor, vscode...): IN đoạn cấu hình MCP/hook, không tự sửa file. Không tham số: liệt kê agent
#   rg wrap -Agent X -- lệnh # chạy một lệnh agent bất kỳ trong một phiên được Resource Guard ghi nhận (cho agent không có MCP lẫn hook)
#   rg mcp                   # chạy MCP server qua stdio (agent tự gọi lệnh này; xem rg connect)
#   rg version               # phiên bản
#   rg panic                 # DỪNG KHẨN CẤP: tắt chính sách tự động + huỷ mọi job nền của Resource Guard (không cần PIN; bật lại cần PIN)
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('start', 'open', 'stop', 'restart', 'status', 'run', 'autostart', 'shortcut', 'path', 'pin', 'hooks', 'panic', 'connect', 'wrap', 'mcp', 'version', 'help')][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Arg = '',
    [int]$Port = 8765, [switch]$Force, [switch]$NoOpen, [switch]$Desktop, [switch]$Heavy, [string]$Agent = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
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
function Get-RgVersionLite { try { ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim() } catch { '0.0.0-dev' } }
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
        "Resource Guard $(Get-RgVersionLite)"
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
        "Đã thêm $root vào PATH người dùng. Mở terminal mới rồi gõ: rguard status"
        # `rg` trùng tên ripgrep: nếu máy có rg.exe thì cảnh báo và chỉ cách dùng `rguard` (luôn đúng là Resource Guard).
        $rgExe = @(Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Source -Parent).TrimEnd('\') -ine $root.TrimEnd('\') }) | Select-Object -First 1
        if ($rgExe) { "Lưu ý: máy có ripgrep ($($rgExe.Source)). Gõ 'rg' trong terminal có thể chạy ripgrep thay vì Resource Guard; hãy dùng lệnh 'rguard' (cùng tham số)." }
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
    'version' { "Resource Guard $(Get-RgVersionLite)" }
    'mcp' { & (Join-Path $root 'scripts\rg-mcp.ps1') -Agent $Agent }
    'connect' {
        . (Join-Path $root 'scripts\rg-common.ps1')
        if (-not $Arg) {
            'Agent có thể kết nối (rg connect <id>):'
            Get-RgAgentCatalog | Where-Object { @($_.connect).Count } | ForEach-Object { '  {0,-9} {1,-38} {2}' -f $_.id, $_.label, (@($_.connect) -join ', ') }
            ''
            'Agent khác có hỗ trợ MCP: dùng khối mcpServers của "rg connect vscode". Script/CI: POST http://localhost:8765/api/connect/v1/preflight (header X-RG-Client: agent).'
            return
        }
        $g = Get-RgConnectGuide $Arg $root -Heavy:$Heavy
        [Console]::Error.WriteLine("Kết nối $($g.label) với Resource Guard. Resource Guard KHÔNG tự sửa file cấu hình của bạn: hãy tự dán các đoạn dưới đây.")
        [Console]::Error.WriteLine($g.status)
        foreach ($s in $g.steps) {
            ''
            "## $($s.title)" + $(if ($s.file) { "  ->  $($s.file)" } else { '' })
            if ($s.note) { "#  $($s.note)" }
            $s.text
        }
    }
    'wrap' {
        # rg wrap -Agent aider -- aider --model x : lập lease cho phiên, chạy lệnh, trả lease khi lệnh thoát (kể cả khi lỗi/Ctrl+C).
        $cmdLine = @(@($Arg) + @($Rest) | Where-Object { $_ -and $_ -ne '--' })
        if ($cmdLine.Count -eq 0) { 'Dùng: rg wrap -Agent <tên> -- <lệnh> [tham số...]'; return }
        . (Join-Path $root 'scripts\rg-common.ps1')
        $who = $(if ($Agent) { $Agent.ToLowerInvariant() } else { ([IO.Path]::GetFileNameWithoutExtension($cmdLine[0])).ToLowerInvariant() })
        $sid = "wrap-$PID"
        try { [void](New-RgLease -SessionId $sid -Agent $who -OwnerPid $PID -Cwd (Get-Location).Path -Source 'wrap') } catch { [Console]::Error.WriteLine("Resource Guard: không ghi nhận được phiên ($($_.Exception.Message)); vẫn chạy lệnh.") }
        $exit = 0
        try {
            $rest2 = @(); if ($cmdLine.Count -gt 1) { $rest2 = @($cmdLine[1..($cmdLine.Count - 1)]) }
            & $cmdLine[0] @rest2
            $exit = $(if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 })
        } finally { try { [void](Remove-RgLease -SessionId $sid) } catch { } }
        exit $exit
    }
    default {
        Get-Content -LiteralPath $PSCommandPath -TotalCount 17 -Encoding UTF8 | ForEach-Object { $_ -replace '^#   ?', '  ' -replace '^# ', '' }
    }
}
