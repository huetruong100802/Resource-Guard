# rg-hook.ps1 - cầu nối hook của agent -> lease phiên, giữ chỗ preflight, đếm subagent (plan-automation C3; nhiều agent: plan-product G3).
#   -Agent claude (mặc định) | gemini | cursor | <id trong agents.catalog>: chọn bảng chuẩn hoá sự kiện (rg-agents.ps1, $script:RgHookMaps).
# Claude Code chạy script này cho mỗi sự kiện đã khai báo trong settings (xem `rg.ps1 hooks print`), JSON sự kiện nằm trên stdin.
#   SessionStart/UserPromptSubmit/Stop : nhận/làm mới lease của phiên (token fencing)    SessionEnd : trả lease và mọi giữ chỗ
#   PreToolUse (Task|Agent, tuỳ chọn Bash) : preflight có giữ chỗ; bị từ chối => thoát mã 2 + lý do ở stderr (Claude Code chặn tool)
#   SubagentStop / PostToolUse            : nhả giữ chỗ tương ứng
# Chạy được khi Resource Guard (server) KHÔNG chạy: chỉ dùng file trong ~/.agent-resource. Mọi lỗi nội bộ => thoát 0 (không làm hỏng phiên của người dùng).
# Không lưu prompt, câu trả lời hay transcript; chỉ session_id, cwd, tên tool, tên tác vụ.
[CmdletBinding()]
param([string]$Agent = 'claude', [int]$OwnerPid = 0)
$ErrorActionPreference = 'Stop'
$code = 0
try {
    . (Join-Path $PSScriptRoot 'rg-common.ps1')
    $raw = ''
    # Đọc stdin dạng BYTE rồi giải mã UTF-8 (agent luôn gửi JSON UTF-8). [Console]::In giải mã theo codepage OEM khi tiến trình không có console,
    # làm hỏng đường dẫn có dấu và biến BOM thành ký tự rác trước dấu '{' (JSON không đọc được => hook im lặng không làm gì).
    try { if ([Console]::IsInputRedirected) { $raw = Read-RgStdinUtf8 } } catch { }
    if ($raw -and $raw.Trim()) {
        # Mỗi agent đặt tên sự kiện/trường một kiểu (Claude Code, Gemini CLI, Cursor...): chuẩn hoá về một dạng rồi mới xử lý.
        $payload = ConvertTo-RgHookPayload ($raw | ConvertFrom-Json) $Agent
        $r = Invoke-RgHookEvent -Payload $payload -Agent $Agent -OwnerPid $OwnerPid
        Write-RgLog 'hook' ([ordered]@{ agent = $Agent; event = $r.event; action = $r.action; block = $r.block })
        if ((Get-RgHookMap $Agent).reply -eq 'cursor') {
            # Cursor đọc quyết định từ stdout dạng JSON, không dùng mã thoát 2.
            if ($r.event -eq 'PreToolUse') { [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ permission = $(if ($r.block) { 'deny' } else { 'allow' }); userMessage = [string]$r.message; agentMessage = [string]$r.message }) -Compress)) }
        }
        elseif ($r.block) { [Console]::Error.WriteLine($r.message); $code = 2 }
        elseif ($r.PSObject.Properties['warning'] -and $r.warning) { [Console]::Error.WriteLine([string]$r.warning) }
    }
} catch {
    try { Write-RgLog 'hook-error' ([ordered]@{ error = [string]$_.Exception.Message }) } catch { }
}
exit $code
