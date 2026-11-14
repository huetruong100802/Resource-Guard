# Test nghiệm thu cho kết nối agent (plan-product G3). Chạy riêng: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Acceptance-Agents.ps1
# Tests\Acceptance.ps1 cũng gọi file này ở cuối. Mọi thứ nằm trong thư mục tạm riêng (AGENT_RESOURCE_HOME); nhà cung cấp AI là lệnh giả và
# máy chủ HTTP giả trên localhost: không gọi dịch vụ thật nào, không tốn tiền.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("rg-agents-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$home_ = Join-Path $sandbox 'home'
[void](New-Item -ItemType Directory -Force -Path $home_)
$env:AGENT_RESOURCE_HOME = $home_

$script:pass = 0; $script:fail = 0
function Assert($Cond, [string]$Name) {
    if ([bool]$Cond) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

# Máy chủ HTTP giả (runspace riêng): trả lời /v1/chat/completions (kiểu OpenAI) và /api/chat (kiểu Ollama), ghi lại header Authorization.
function Start-FakeLlm([int]$Port, [string]$Mode) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($Port, $Mode, $Seen, $Box)
            $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/"); $l.Start(); $Box.l = $l
            try {
                while ($true) {
                    $c = $l.GetContext()
                    $body = (New-Object IO.StreamReader($c.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                    [void]$Seen.Add([pscustomobject]@{ path = $c.Request.Url.AbsolutePath; auth = [string]$c.Request.Headers['Authorization']; body = $body })
                    $content = $(if ($Mode -eq 'bad') { '{"ok":"khong phai bool"}' } else { 'Đây là kết quả: {"ok":true,"note":"xin chào"}' })
                    $resp = $(if ($c.Request.Url.AbsolutePath -eq '/api/chat') { @{ message = @{ role = 'assistant'; content = $content } } } else { @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }) } })
                    $b = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $resp -Depth 6 -Compress))
                    $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
                }
            } finally { $l.Stop() }
        }).AddArgument($Port).AddArgument($Mode).AddArgument($script:Seen).AddArgument(($box = [hashtable]::Synchronized(@{})))
    $h = $ps.BeginInvoke()
    for ($i = 0; $i -lt 40 -and -not $box.l; $i++) { Start-Sleep -Milliseconds 50 }
    return [pscustomobject]@{ ps = $ps; rs = $rs; h = $h; box = $box }
}
# Dừng listener từ ngoài làm GetContext() đang chờ ném lỗi -> vòng lặp thoát; gọi $ps.Stop() trực tiếp sẽ treo vì GetContext chặn.
function Stop-FakeLlm($S) { try { $S.box.l.Stop(); $S.box.l.Close() } catch { }; try { [void]$S.h.AsyncWaitHandle.WaitOne(3000) } catch { }; try { $S.rs.Close() } catch { } }
function Get-FreePort { $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $t.Start(); $p = $t.LocalEndpoint.Port; $t.Stop(); return $p }

$port1 = Get-FreePort; $port2 = Get-FreePort
$fakeCmd = Join-Path $sandbox 'fake-llm.cmd'
[IO.File]::WriteAllText($fakeCmd, "@echo off`r`necho Ket qua: {`"ok`":true,`"note`":`"chao`"}`r`n", (New-Object Text.ASCIIEncoding))
$cfg = Get-Content (Join-Path $root 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$prov = $cfg.agents.providers
$prov | Add-Member -NotePropertyName fakecli -NotePropertyValue ([pscustomobject]@{ label = 'CLI giả'; type = 'cli'; command = $fakeCmd; args = ''; parse = 'text' })
$prov | Add-Member -NotePropertyName fakeoai -NotePropertyValue ([pscustomobject]@{ label = 'OpenAI giả'; type = 'http'; api = 'openai'; baseUrl = "http://localhost:$port1/v1"; apiKeyEnv = 'RG_TEST_FAKE_KEY'; model = 'gia-1'; responseFormat = 'json_schema' })
$prov | Add-Member -NotePropertyName fakeollama -NotePropertyValue ([pscustomobject]@{ label = 'Ollama giả'; type = 'http'; api = 'ollama'; baseUrl = "http://localhost:$port1"; model = 'gia-ollama' })
$prov | Add-Member -NotePropertyName fakebad -NotePropertyValue ([pscustomobject]@{ label = 'Sai dạng'; type = 'http'; api = 'openai'; baseUrl = "http://localhost:$port2/v1"; model = 'x'; responseFormat = 'none' })
Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 10) -Encoding UTF8

. (Join-Path $root 'scripts\rg-common.ps1')
$script:Seen = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
$secret = 'sk-test-' + [guid]::NewGuid().ToString('N')
$env:RG_TEST_FAKE_KEY = $secret
$fake1 = $null; $fake2 = $null; $mcp = $null
$schema = '{"type":"object","additionalProperties":false,"properties":{"ok":{"type":"boolean"},"note":{"type":"string"}},"required":["ok","note"]}'
try {
    # =====================================================================
    Write-Host "`n[G3.1] Danh mục agent"
    $cat = @(Get-RgAgentCatalog)
    Assert ($cat.Count -ge 10) "danh mục có $($cat.Count) agent (>= 10)"
    foreach ($id in 'claude', 'codex', 'gemini', 'cursor', 'copilot', 'vscode', 'aider', 'ollama') { Assert (@($cat | Where-Object { $_.id -eq $id }).Count -eq 1) "danh mục có '$id'" }
    Assert ((Get-RgAgentOf 'codex' '').id -eq 'codex') 'tiến trình codex.exe -> codex'
    Assert ((Get-RgAgentOf 'node' 'node C:\Users\x\AppData\Roaming\npm\node_modules\@google\gemini-cli\dist\index.js').id -eq 'gemini') 'node chạy @google/gemini-cli -> gemini'
    Assert ((Get-RgAgentOf 'node' 'node C:\src\app\server.js') -eq $null) 'node chạy app thường -> không phải agent'
    Assert ((Get-RgAgentOf 'notepad' '') -eq $null) 'notepad -> không phải agent'
    Assert ((Get-RgAgentOf 'ollama' '').kind -eq 'runtime') 'ollama được nhận là runtime LLM (không phải agent)'
    $c2 = Get-RgConfig
    Assert ((Get-RgGroup 'gemini' '' $c2) -eq 'agent') 'Get-RgGroup: gemini thuộc nhóm agent'
    Assert (@($c2.protected.segments) -contains '.gemini' -and @($c2.protected.segments) -contains '.cursor') 'thư mục cấu hình agent nằm trong vùng bảo vệ'

    # =====================================================================
    Write-Host "`n[G3.3] Chuẩn hoá hook nhiều agent"
    $g = ConvertTo-RgHookPayload ([pscustomobject]@{ hook_event_name = 'BeforeTool'; session_id = 'g1'; cwd = 'C:\w'; tool_name = 'run_shell_command'; tool_input = [pscustomobject]@{ command = 'npm test' } }) 'gemini'
    Assert ($g.hook_event_name -eq 'PreToolUse' -and $g.tool_name -eq 'Bash' -and $g.tool_input.command -eq 'npm test' -and $g.session_id -eq 'g1') 'Gemini BeforeTool/run_shell_command -> PreToolUse/Bash'
    $cu = ConvertTo-RgHookPayload ([pscustomobject]@{ hook_event_name = 'beforeShellExecution'; conversation_id = 'c9'; workspace_roots = @('C:\proj', 'C:\b'); command = 'dotnet build' }) 'cursor'
    Assert ($cu.hook_event_name -eq 'PreToolUse' -and $cu.tool_name -eq 'Bash' -and $cu.session_id -eq 'c9' -and $cu.cwd -eq 'C:\proj' -and $cu.tool_input.command -eq 'dotnet build') 'Cursor beforeShellExecution -> PreToolUse/Bash, cwd = workspace đầu tiên'
    $cl = ConvertTo-RgHookPayload ([pscustomobject]@{ hook_event_name = 'PreToolUse'; session_id = 's'; cwd = 'C:\x'; tool_name = 'Agent'; tool_input = [pscustomobject]@{} }) 'claude'
    Assert ($cl.tool_name -eq 'Task') 'Claude Code tool Agent -> Task (subagent)'
    $unk = ConvertTo-RgHookPayload ([pscustomobject]@{ hook_event_name = 'SessionStart'; session_id = 'u1'; cwd = 'C:\x' }) 'khong-co'
    Assert ($unk.hook_event_name -eq 'SessionStart' -and $unk.session_id -eq 'u1') 'agent lạ: coi như gửi đúng dạng chuẩn'

    # =====================================================================
    Write-Host "`n[G3.2] Cửa kiểm kết quả chung"
    $so = ConvertFrom-Json $schema
    Assert ((Get-RgFirstJsonObject 'Chào bạn ```json {"ok":true,"note":"a{b}"} ``` hết') -eq '{"ok":true,"note":"a{b}"}') 'tách khối JSON đầu tiên giữa lời dẫn/markdown (kể cả { } trong chuỗi)'
    Assert ((Get-RgFirstJsonObject 'không có json') -eq $null) 'không có JSON -> $null'
    Assert ((Test-RgJsonShape (ConvertFrom-Json '{"ok":true,"note":"x"}') $so) -eq '') 'đúng schema -> hợp lệ'
    Assert ((Test-RgJsonShape (ConvertFrom-Json '{"ok":true}') $so) -match 'thiếu') 'thiếu trường required -> lỗi'
    Assert ((Test-RgJsonShape (ConvertFrom-Json '{"ok":"yes","note":"x"}') $so) -match 'true/false') 'sai kiểu -> lỗi'
    $se = ConvertFrom-Json '{"type":"object","properties":{"v":{"type":"string","enum":["keep","delete"]}}}'
    Assert ((Test-RgJsonShape (ConvertFrom-Json '{"v":"rm -rf"}') $se) -match 'ngoài danh sách') 'giá trị ngoài enum -> lỗi'

    Write-Host "`n[G3.2] Nhà cung cấp CLI giả"
    $pv = @(Get-RgProviders | Where-Object { $_.id -eq 'fakecli' })[0]
    Assert ($pv -and (Test-RgProviderReady $pv).ok) 'nhà cung cấp CLI khai trong config được nhận và sẵn sàng'
    Assert ($pv.verified -eq $false) 'nhà cung cấp tự khai luôn bị đánh dấu chưa kiểm'
    $r = Invoke-RgLlmJson -Prompt 'thử' -Schema $schema -Provider $pv -TimeoutSec 30
    Assert ($r.data.ok -eq $true -and $r.data.note -eq 'chao' -and $r.provider -eq 'fakecli') 'CLI giả: lời dẫn + JSON -> kết quả đúng dạng'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $home_ 'state\agent-cwd') -File -ErrorAction SilentlyContinue).Count -eq 0) 'CLI: file tạm (schema/prompt/out) được dọn sau khi gọi'

    Write-Host "`n[G3.2] Nhà cung cấp HTTP giả (OpenAI-compatible, Ollama)"
    $fake1 = Start-FakeLlm $port1 'ok'
    $po = @(Get-RgProviders | Where-Object { $_.id -eq 'fakeoai' })[0]
    Assert ($po.local -eq $true) 'baseUrl localhost -> nhà cung cấp cục bộ (suy từ địa chỉ, không tin lời khai)'
    $r = Invoke-RgLlmJson -Prompt 'thử tiếng Việt có dấu' -Schema $schema -Provider $po -TimeoutSec 20
    Assert ($r.data.ok -eq $true -and $r.data.note -eq 'xin chào') 'OpenAI giả: đọc choices[0].message.content, giữ đúng tiếng Việt'
    $req = @($script:Seen | Where-Object { $_.path -eq '/v1/chat/completions' })[0]
    Assert ($req -and $req.auth -eq "Bearer $secret") 'khoá API lấy từ biến môi trường apiKeyEnv và gửi trong header'
    Assert ($req -and $req.body -match '"response_format"' -and $req.body -match '"json_schema"' -and $req.body -match '"model":"gia-1"') 'gửi response_format json_schema + model'
    $pl = @(Get-RgProviders | Where-Object { $_.id -eq 'fakeollama' })[0]
    $r = Invoke-RgLlmJson -Prompt 'thử' -Schema $schema -Provider $pl -TimeoutSec 20
    $reqO = @($script:Seen | Where-Object { $_.path -eq '/api/chat' })[0]
    Assert ($r.data.ok -eq $true -and $r.local -eq $true) 'Ollama giả: kết quả đúng, đánh dấu chạy trên máy'
    Assert ($reqO -and $reqO.body -match '"format":\{' -and $reqO.body -match '"stream":false') 'Ollama: gửi schema qua "format", không stream'
    $fake2 = Start-FakeLlm $port2 'bad'
    $pb = @(Get-RgProviders | Where-Object { $_.id -eq 'fakebad' })[0]
    $err = ''; try { [void](Invoke-RgLlmJson -Prompt 'x' -Schema $schema -Provider $pb -TimeoutSec 20) } catch { $err = [string]$_.Exception.Message }
    Assert ($err -match 'sai dạng') 'nhà cung cấp trả sai schema -> bị loại ở cửa chung'
    $reqB = @($script:Seen | Where-Object { $_.body -match '"model":"x"' })[0]
    Assert ($reqB -and $reqB.body -match 'JSON Schema') 'nhà cung cấp không ép được schema: schema được nhét vào prompt'
    $t = Test-RgProviderCall 'fakeoai'
    Assert ($t.ok -and $t.note -eq 'xin chào') 'Test-RgProviderCall (nút "Thử kết nối") chạy qua cùng đường'
    $logText = (Get-ChildItem -LiteralPath (Join-Path $home_ 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    $stateText = (Get-ChildItem -LiteralPath (Join-Path $home_ 'state') -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Assert (-not $logText.Contains($secret) -and -not $stateText.Contains($secret)) 'khoá API không xuất hiện trong logs\ hay state\'

    Write-Host "`n[G3.2] Chọn nhà cung cấp đánh giá"
    [void](Set-RgEvaluatorChoice 'fakeoai' 'gia-2')
    $ev = Get-RgEvaluator -NoCache
    Assert ($ev.id -eq 'fakeoai' -and $ev.model -eq 'gia-2') 'chọn nhà cung cấp + model -> Get-RgEvaluator trả đúng'
    $threw = $false; try { [void](Set-RgEvaluatorChoice 'khong-ton-tai' '') } catch { $threw = $true }
    Assert $threw 'không chọn được id ngoài config'
    $v = Get-RgAgentsView (Get-RgConfig) $null
    Assert (@($v.agents).Count -ge 10 -and @($v.providers | Where-Object { $_.id -eq 'fakeoai' -and $_.ready }).Count -eq 1 -and $v.choice.provider -eq 'fakeoai') 'Get-RgAgentsView: danh mục + nhà cung cấp + lựa chọn'
    Assert (-not ((ConvertTo-Json $v -Depth 8) -match [regex]::Escape($secret))) 'Get-RgAgentsView không lộ khoá API'
    [void](Set-RgEvaluatorChoice 'auto' '')

    # =====================================================================
    Write-Host "`n[G3.3] Hướng dẫn kết nối (rguard connect)"
    foreach ($a in @($cat | Where-Object { @($_.connect).Count })) {
        $gd = Get-RgConnectGuide $a.id $root
        $bad = @()
        foreach ($s in @($gd.steps)) { if ($s.lang -eq 'json') { try { [void](ConvertFrom-Json $s.text) } catch { $bad += $s.title } } }
        Assert (@($gd.steps).Count -ge 1 -and $bad.Count -eq 0) "$($a.id): $(@($gd.steps).Count) bước, mọi đoạn JSON hợp lệ$(if ($bad) { ' (lỗi: ' + ($bad -join ', ') + ')' })"
    }
    $gc = Get-RgConnectGuide 'codex' $root
    Assert (($gc.steps[0].text -match '\[mcp_servers\.resource-guard\]') -and ($gc.steps[0].text -match 'rg-mcp\.ps1')) 'codex: khối TOML mcp_servers trỏ tới rg-mcp.ps1'
    $threw = $false; try { [void](Get-RgConnectGuide 'khong-co' $root) } catch { $threw = $true }
    Assert $threw 'agent không có trong danh mục -> lỗi rõ ràng'

    # =====================================================================
    Write-Host "`n[G3.3] MCP server qua stdio thật"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'scripts\rg-mcp.ps1') + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.EnvironmentVariables['AGENT_RESOURCE_HOME'] = $home_
    $mcp = [Diagnostics.Process]::Start($psi)
    $inW = New-Object IO.StreamWriter($mcp.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false))); $inW.AutoFlush = $true
    $errT = $mcp.StandardError.ReadToEndAsync()
    function McpCall([string]$Json, [int]$TimeoutMs = 60000) {
        $inW.WriteLine($Json)
        $t = $mcp.StandardOutput.ReadLineAsync()
        if (-not $t.Wait($TimeoutMs)) { throw 'MCP không trả lời' }
        return (ConvertFrom-Json $t.Result)
    }
    $init = McpCall '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gemini-cli-mcp-client","version":"1"}}}'
    Assert ($init.id -eq 1 -and $init.result.protocolVersion -eq '2025-06-18' -and $init.result.serverInfo.name -eq 'resource-guard' -and $init.result.capabilities.tools) 'initialize: phiên bản giao thức, serverInfo, capabilities.tools'
    $inW.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')   # notification: không có phản hồi
    $lease = @(Get-RgLeases | Where-Object { [string]$_.sessionId -like 'mcp-*' })
    Assert ($lease.Count -eq 1 -and $lease[0].agent -eq 'gemini' -and ([string]$lease[0].source) -like 'mcp*') 'initialize mở lease, nhận ra agent từ clientInfo (gemini)'
    $tl = McpCall '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    $names = @($tl.result.tools | ForEach-Object { $_.name })
    Assert ($tl.id -eq 2 -and $names.Count -eq 5 -and ($names -contains 'preflight') -and ($names -contains 'resource_status')) "tools/list: $($names -join ', ')"
    Assert (-not ($names | Where-Object { $_ -match 'delete|kill|remove|clean_?up$|terminate' })) 'không có công cụ xoá/kết thúc nào'
    Assert (@($tl.result.tools | Where-Object { -not $_.inputSchema -or $_.inputSchema.type -ne 'object' }).Count -eq 0) 'mọi công cụ có inputSchema kiểu object'
    $pf = McpCall '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"preflight","arguments":{"task":"build"}}}' 90000
    $pfr = ConvertFrom-Json $pf.result.content[0].text
    Assert ($pf.id -eq 3 -and $pf.result.isError -eq $false -and @('allow', 'warn', 'deny') -contains [string]$pfr.decision -and $pfr.state) "preflight build -> $($pfr.decision) ($($pfr.state))"
    $rl = McpCall '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"release","arguments":{"task":"build"}}}'
    Assert ($rl.result.isError -eq $false) 'release: nhả giữ chỗ'
    $bad = McpCall '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"preflight","arguments":{"task":"rm"}}}'
    Assert ($bad.result.isError -eq $true) 'tham số sai -> isError (không làm sập server)'
    $unk = McpCall '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"delete_files","arguments":{}}}'
    Assert ($unk.error.code -eq -32602) 'công cụ không tồn tại -> lỗi -32602'
    $nf = McpCall '{"jsonrpc":"2.0","id":7,"method":"resources/list"}'
    Assert ($nf.error.code -eq -32601) 'method lạ -> -32601'
    $pe = McpCall 'không phải json'
    Assert ($pe.error.code -eq -32700) 'dòng không phải JSON -> -32700 và server vẫn chạy'
    $pg = McpCall '{"jsonrpc":"2.0","id":8,"method":"ping"}'
    Assert ($pg.id -eq 8 -and $null -ne $pg.result) 'ping sau lỗi vẫn trả lời'
    $inW.Close()
    [void]$mcp.WaitForExit(20000)
    Assert ($mcp.HasExited) 'đóng stdin -> MCP server thoát'
    Assert (@(Get-RgLeases | Where-Object { [string]$_.sessionId -like 'mcp-*' }).Count -eq 0) 'MCP thoát -> trả lease và giữ chỗ'
    $mcpErr = [string]$errT.Result
    Assert (-not $mcpErr.Trim()) 'stdout chỉ có JSON, stderr sạch'
}
finally {
    if ($mcp -and -not $mcp.HasExited) { try { $mcp.Kill() } catch { } }
    if ($fake1) { Stop-FakeLlm $fake1 }; if ($fake2) { Stop-FakeLlm $fake2 }
    Remove-Item Env:\RG_TEST_FAKE_KEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_RESOURCE_HOME -ErrorAction SilentlyContinue
}
Write-Host ("`nKết quả (agents): {0} pass, {1} fail" -f $script:pass, $script:fail)
Write-Host ("AGENTS-RESULT pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
