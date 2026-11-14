# rg-mcp.ps1 - MCP server (Model Context Protocol) của Resource Guard qua stdio. Mọi agent hỗ trợ MCP dùng được: Claude Code, Codex CLI,
# Gemini CLI, Cursor, Windsurf, VS Code (Copilot Chat, Cline, Roo), opencode, Goose...
#   Giao thức: JSON-RPC 2.0, mỗi dòng một thông điệp UTF-8 trên stdin/stdout. stdout CHỈ có JSON (log đi vào logs\rg-*.jsonl).
#   Công cụ (rg-agents.ps1): resource_status, preflight, release, cleanup_candidates, explain_process. CHỈ đọc + tư vấn + giữ chỗ:
#   không có công cụ nào xoá file hay kết thúc tiến trình (agent đề xuất, con người duyệt trong giao diện).
#   Chạy được khi server Resource Guard KHÔNG chạy: chỉ dùng file trong ~/.agent-resource và số đo trực tiếp.
# Cấu hình cho từng agent: `rguard connect <agent>`.
[CmdletBinding()]
param([string]$Agent = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
. (Join-Path $PSScriptRoot 'rg-proc.ps1')

$utf8 = New-Object Text.UTF8Encoding($false)
$stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = [Console]::OpenStandardOutput()
function Send-Line([string]$Json) { $b = $utf8.GetBytes($Json + "`n"); $stdout.Write($b, 0, $b.Length); $stdout.Flush() }

$state = @{ sessionId = "mcp-$PID"; agent = $(if ($Agent) { $Agent } else { 'unknown' }); ownerPid = 0; source = 'mcp'; client = '' }
try { $state.ownerPid = [int](Find-RgAgentOwnerPid) } catch { }
Write-RgLog 'mcp-start' ([ordered]@{ pid = $PID; ownerPid = $state.ownerPid })
try {
    while ($null -ne ($line = $stdin.ReadLine())) {
        $line = $line.Trim().TrimStart([char]0xFEFF)
        if (-not $line) { continue }
        $msg = $null; $resp = $null
        try { $msg = ConvertFrom-Json $line } catch { Send-Line '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'; continue }
        try {
            $resp = Invoke-RgMcpMessage $msg $state
            if ($Agent) { $state.agent = $Agent }   # -Agent khai tay thắng tên client tự nhận
        } catch {
            Write-RgLog 'mcp-error' ([ordered]@{ error = [string]$_.Exception.Message })
            if ($msg -and $msg.PSObject.Properties['id']) { $resp = [ordered]@{ jsonrpc = '2.0'; id = $msg.id; error = [ordered]@{ code = -32603; message = 'Internal error' } } }
        }
        if ($null -ne $resp) { Send-Line (ConvertTo-Json -InputObject $resp -Depth 12 -Compress) }
    }
} finally {
    try { [void](Remove-RgLease -SessionId $state.sessionId) } catch { }   # agent đóng kết nối: trả lease và mọi giữ chỗ
    try { Write-RgLog 'mcp-stop' ([ordered]@{ pid = $PID; agent = $state.agent }) } catch { }
}
