# rg-hook.ps1 - cầu nối hook của Claude Code -> lease phiên, giữ chỗ preflight, đếm subagent (plan-automation C3).
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
    try { if ([Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd() } } catch { }
    if ($raw -and $raw.Trim()) {
        $payload = $raw | ConvertFrom-Json
        $r = Invoke-RgHookEvent -Payload $payload -Agent $Agent -OwnerPid $OwnerPid
        Write-RgLog 'hook' ([ordered]@{ event = $r.event; action = $r.action; block = $r.block })
        if ($r.block) { [Console]::Error.WriteLine($r.message); $code = 2 }
        elseif ($r.PSObject.Properties['warning'] -and $r.warning) { [Console]::Error.WriteLine([string]$r.warning) }
    }
} catch {
    try { Write-RgLog 'hook-error' ([ordered]@{ error = [string]$_.Exception.Message }) } catch { }
}
exit $code
