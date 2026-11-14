# rg-agents.ps1 - kết nối agent (plan-product G3). Dot-source từ rg-common.ps1; chỉ định nghĩa hàm.
#   1. Danh mục agent (cfg.agents.catalog): nhận diện tiến trình, thư mục cấu hình, cách kết nối. Thêm agent mới = thêm một mục config, không sửa code.
#   2. Nhà cung cấp LLM đánh giá (cfg.agents.providers): claude | codex | gemini (CLI), ollama | openai-compatible (HTTP). Mọi kết quả đi qua
#      cùng một cửa: tách JSON -> Test-RgJsonShape -> (ở nơi gọi) bộ lọc an toàn sẵn có. Agent CHỈ đề xuất.
#   3. Agent báo cho Resource Guard: chuẩn hoá hook nhiều agent, công cụ MCP (rg-mcp.ps1), HTTP /api/connect/v1/*. Chỉ đọc + tư vấn:
#      không có công cụ nào xoá file hay kết thúc tiến trình.
# Khoá API chỉ đọc từ biến môi trường, không bao giờ ghi vào file hay log.

# ---------- 1. Danh mục agent ----------

# Danh mục dự phòng khi config không có khoá agents (config cũ của người dùng, config rút gọn trong test).
$script:RgAgentCatalogFallback = @(
    [pscustomobject]@{ id = 'claude'; label = 'Claude Code'; kind = 'cli'; cli = 'claude'; processNames = @('claude'); cmdRegex = '@anthropic-ai[\\/]claude-code|claude-code|[\\/]\.claude[\\/]'; connect = @('hooks', 'mcp'); hooks = 'claude' },
    [pscustomobject]@{ id = 'codex'; label = 'Codex CLI'; kind = 'cli'; cli = 'codex'; processNames = @('codex'); cmdRegex = '@openai[\\/]codex|[\\/]\.codex[\\/]'; connect = @('mcp', 'wrapper') }
)

function Get-RgAgentCatalog($Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $out = @()
    try {
        if ($Cfg.PSObject.Properties['agents'] -and $Cfg.agents -and $Cfg.agents.PSObject.Properties['catalog'] -and $Cfg.agents.catalog) {
            foreach ($p in $Cfg.agents.catalog.PSObject.Properties) {
                $v = $p.Value
                if (-not $v -or ($v.PSObject.Properties['enabled'] -and $v.enabled -eq $false)) { continue }
                $get = { param($n, $d) if ($v.PSObject.Properties[$n] -and $null -ne $v.$n) { $v.$n } else { $d } }
                $out += [pscustomobject][ordered]@{
                    id = [string]$p.Name; label = [string](& $get 'label' $p.Name); kind = [string](& $get 'kind' 'cli'); cli = [string](& $get 'cli' '')
                    processNames = @((& $get 'processNames' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ })
                    cmdRegex = [string](& $get 'cmdRegex' ''); connect = @((& $get 'connect' @('mcp')) | ForEach-Object { [string]$_ })
                    hooks = [string](& $get 'hooks' ''); mcpClient = [string](& $get 'mcpClient' ''); note = [string](& $get 'note' '')
                }
            }
        }
    } catch { }
    if ($out.Count -eq 0) { return @($script:RgAgentCatalogFallback) }
    return $out
}

# Chỉ mục nhận diện dựng một lần cho mỗi đối tượng config (Get-RgGroup gọi cho từng tiến trình).
$script:RgAgentIdxCfg = $null; $script:RgAgentIdx = $null
function Get-RgAgentIndex($Cfg) {
    if ($script:RgAgentIdx -and [object]::ReferenceEquals($script:RgAgentIdxCfg, $Cfg)) { return $script:RgAgentIdx }
    $cli = @(); $runtime = @(); $rx = @(); $byName = @{}
    foreach ($a in (Get-RgAgentCatalog $Cfg)) {
        foreach ($n in @($a.processNames)) {
            if ($a.kind -eq 'cli') { $cli += $n } elseif ($a.kind -eq 'runtime') { $runtime += $n }
            if (-not $byName.ContainsKey($n)) { $byName[$n] = $a }
        }
        if ($a.kind -eq 'cli' -and $a.cmdRegex) { $rx += [pscustomobject]@{ agent = $a; regex = (New-Object Text.RegularExpressions.Regex($a.cmdRegex, 'IgnoreCase')) } }
    }
    $idx = [pscustomobject]@{ cli = @($cli); runtime = @($runtime); regex = @($rx); byName = $byName }
    $script:RgAgentIdxCfg = $Cfg; $script:RgAgentIdx = $idx
    return $idx
}

$script:RgAgentHostNames = @('node', 'bun', 'deno', 'python', 'python3', 'pythonw', 'uv', 'uvx')

# Mục danh mục của một tiến trình ($null nếu không phải agent): tên khớp processNames, hoặc là node/bun/python... có dòng lệnh khớp cmdRegex.
function Get-RgAgentOf([string]$Name, [string]$Cmd, $Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $idx = Get-RgAgentIndex $Cfg
    $n = ([string]$Name).ToLowerInvariant()
    if ($idx.byName.ContainsKey($n)) { return $idx.byName[$n] }
    if ($Cmd -and ($script:RgAgentHostNames -contains $n)) { foreach ($r in $idx.regex) { if ($r.regex.IsMatch($Cmd)) { return $r.agent } } }
    return $null
}

# ---------- 2. Nhà cung cấp LLM ----------

# Mặc định trong code; cfg.agents.providers.<id> ghi đè từng khoá. Cờ dòng lệnh của CLI bên thứ ba nằm ở đây để người dùng chỉnh qua config
# khi bản CLI của họ khác. `verified`: đã chạy với sản phẩm thật trên máy phát triển hay mới kiểm bằng lệnh/máy chủ giả đúng hợp đồng.
$script:RgProviderDefaults = [ordered]@{
    claude = @{ label = 'Claude Code (CLI)'; type = 'cli'; command = 'claude'; model = 'haiku'; local = $false; parse = 'claude'; verified = $true
        args = '-p --model {model} --effort {effort} --tools "" --output-format json --no-session-persistence --disable-slash-commands --setting-sources project --max-budget-usd {budget} --json-schema "{schemaInline}"' }
    codex = @{ label = 'Codex CLI'; type = 'cli'; command = 'codex'; model = ''; modelFlag = '-m'; local = $false; parse = 'text'; verified = $false
        args = 'exec --skip-git-repo-check --sandbox read-only {modelArg} --output-schema "{schemaFile}" --output-last-message "{outFile}" -' }
    gemini = @{ label = 'Gemini CLI'; type = 'cli'; command = 'gemini'; model = ''; modelFlag = '-m'; local = $false; parse = 'gemini'; schemaInPrompt = $true; verified = $false
        args = '{modelArg} --output-format json' }
    ollama = @{ label = 'Ollama (chạy trên máy này)'; type = 'http'; api = 'ollama'; baseUrl = 'http://localhost:11434'; model = ''; local = $true; verified = $false }
    openai = @{ label = 'API tương thích OpenAI'; type = 'http'; api = 'openai'; baseUrl = 'https://api.openai.com/v1'; apiKeyEnv = 'OPENAI_API_KEY'; model = ''; responseFormat = 'json_schema'; local = $false; verified = $false }
}

function Get-RgProviders($Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $over = $null
    try { if ($Cfg.PSObject.Properties['agents'] -and $Cfg.agents -and $Cfg.agents.PSObject.Properties['providers']) { $over = $Cfg.agents.providers } } catch { }
    $ids = New-Object System.Collections.ArrayList
    foreach ($k in $script:RgProviderDefaults.Keys) { [void]$ids.Add([string]$k) }
    if ($over) { foreach ($p in $over.PSObject.Properties) { if (-not $ids.Contains([string]$p.Name)) { [void]$ids.Add([string]$p.Name) } } }
    $out = @()
    foreach ($id in $ids) {
        $h = [ordered]@{ id = $id; label = $id; type = 'cli'; command = ''; args = ''; model = ''; modelFlag = ''; effort = ''; parse = 'text'; schemaInPrompt = $false
            api = ''; baseUrl = ''; apiKeyEnv = ''; responseFormat = 'json_schema'; local = $false; verified = $false; enabled = $true }
        if ($script:RgProviderDefaults.Contains($id)) { foreach ($k in $script:RgProviderDefaults[$id].Keys) { $h[$k] = $script:RgProviderDefaults[$id][$k] } }
        if ($over -and $over.PSObject.Properties[$id] -and $over.$id) {
            foreach ($p in $over.$id.PSObject.Properties) { if ($h.Contains([string]$p.Name) -and $p.Name -ne 'id' -and $null -ne $p.Value) { $h[[string]$p.Name] = $p.Value } }
            if (-not $script:RgProviderDefaults.Contains($id)) { $h.verified = $false }
        }
        if ($h.type -eq 'http') {
            $h.baseUrl = ([string]$h.baseUrl).TrimEnd('/')
            $isLocal = $false
            try { $u = [uri]$h.baseUrl; $isLocal = (@('localhost', '127.0.0.1', '::1', '[::1]') -contains $u.Host) } catch { }
            $h.local = $isLocal   # "cục bộ" suy từ địa chỉ thật, không tin lời khai trong config
        }
        if ($h.enabled) { $out += [pscustomobject]$h }
    }
    return $out
}

# Lệnh CLI thật để khởi chạy bằng CreateProcess: { file; prefix }. Shim của npm (.cmd/.ps1) không chạy thẳng được (UseShellExecute = false), nên:
# ưu tiên .exe; shim .cmd thì đọc đích bên trong ("%dp0%\...exe" hoặc node + .js); không giải được thì chạy qua cmd.exe /c.
function Resolve-RgCli([string]$Command) {
    if (-not $Command) { return $null }
    if ([IO.Path]::IsPathRooted($Command)) { $apps = @(if (Test-Path -LiteralPath $Command -PathType Leaf) { [pscustomobject]@{ Source = $Command } }) }
    else { $apps = @(Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue) }
    if ($apps.Count -eq 0) { return $null }
    $exe = @($apps | Where-Object { $_.Source -match '\.(exe|com)$' }) | Select-Object -First 1
    if ($exe) { return [pscustomobject]@{ file = [string]$exe.Source; prefix = '' } }
    $shim = @($apps | Where-Object { $_.Source -match '\.(cmd|bat)$' }) | Select-Object -First 1
    if ($shim) {
        $dir = Split-Path -Parent ([string]$shim.Source)
        try {
            $txt = [IO.File]::ReadAllText([string]$shim.Source)
            $m = [regex]::Match($txt, '"%(?:~dp0|dp0%)\\?([^"]+\.exe)"', 'IgnoreCase')
            if ($m.Success) { $t = Join-Path $dir $m.Groups[1].Value; if (Test-Path -LiteralPath $t -PathType Leaf) { return [pscustomobject]@{ file = (Resolve-Path -LiteralPath $t).Path; prefix = '' } } }
            $m = [regex]::Match($txt, '"%(?:~dp0|dp0%)\\?([^"]+\.[cm]?js)"', 'IgnoreCase')
            if ($m.Success) {
                $js = Join-Path $dir $m.Groups[1].Value
                $node = Join-Path $dir 'node.exe'
                if (-not (Test-Path -LiteralPath $node)) { $nc = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; $node = $(if ($nc) { [string]$nc.Source } else { '' }) }
                if ($node -and (Test-Path -LiteralPath $js -PathType Leaf)) { return [pscustomobject]@{ file = $node; prefix = ('"' + (Resolve-Path -LiteralPath $js).Path + '" ') } }
            }
        } catch { }
        return [pscustomobject]@{ file = (Join-Path $env:SystemRoot 'System32\cmd.exe'); prefix = ('/d /s /c ""' + [string]$shim.Source + '" '); suffix = '"' }
    }
    return $null
}

# { ok; reason } : nhà cung cấp có dùng được ngay không. Không gọi mạng ra ngoài: máy chủ cục bộ chỉ thử mở cổng (300 ms).
function Test-RgProviderReady($P) {
    if ($P.type -eq 'cli') {
        if (Resolve-RgCli ([string]$P.command)) { return [pscustomobject]@{ ok = $true; reason = '' } }
        return [pscustomobject]@{ ok = $false; reason = "Không tìm thấy lệnh '$($P.command)' trong PATH." }
    }
    if (-not $P.baseUrl) { return [pscustomobject]@{ ok = $false; reason = 'Chưa khai baseUrl trong config.' } }
    if ($P.api -eq 'openai' -and -not $P.model) { return [pscustomobject]@{ ok = $false; reason = 'Chưa khai model trong config (agents.providers.' + $P.id + '.model).' } }
    if ($P.apiKeyEnv -and -not $P.local -and -not [Environment]::GetEnvironmentVariable([string]$P.apiKeyEnv)) { return [pscustomobject]@{ ok = $false; reason = "Chưa có biến môi trường $($P.apiKeyEnv)." } }
    if ($P.local) {
        try {
            $u = [uri]$P.baseUrl; $c = New-Object Net.Sockets.TcpClient
            try { $ar = $c.BeginConnect($u.Host, $u.Port, $null, $null); if (-not $ar.AsyncWaitHandle.WaitOne(300)) { throw 'timeout' }; $c.EndConnect($ar) } finally { $c.Close() }
        } catch { return [pscustomobject]@{ ok = $false; reason = "Không kết nối được $($P.baseUrl) (dịch vụ chưa chạy?)." } }
    }
    return [pscustomobject]@{ ok = $true; reason = '' }
}

function Get-RgEvaluatorStatePath { return (Join-Path (Initialize-RgHome) 'state\agents.json') }
function Read-RgEvaluatorChoice {
    $o = [ordered]@{ provider = ''; model = '' }
    try { $p = Get-RgEvaluatorStatePath; if (Test-Path -LiteralPath $p) { $j = ConvertFrom-Json (Read-RgFileShared $p); $o.provider = [string]$j.provider; $o.model = [string]$j.model } } catch { }
    return [pscustomobject]$o
}

# Người dùng chọn nhà cung cấp ở UI. Chỉ nhận id có trong danh sách (UI không thêm được địa chỉ mới: baseUrl chỉ đến từ file config).
function Set-RgEvaluatorChoice([string]$Provider, [string]$Model = '') {
    $Provider = ([string]$Provider).Trim(); $Model = ([string]$Model).Trim()
    if ($Provider -and $Provider -ne 'auto' -and @(Get-RgProviders | Where-Object { $_.id -eq $Provider }).Count -eq 0) { throw "Không có nhà cung cấp '$Provider'." }
    if ($Model -and $Model -notmatch '^[A-Za-z0-9._:/@-]{1,80}$') { throw 'Tên model không hợp lệ.' }
    if ($Provider -eq 'auto') { $Provider = '' }
    Write-RgFileAtomic (Get-RgEvaluatorStatePath) (ConvertTo-Json -InputObject ([ordered]@{ provider = $Provider; model = $Model; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') }) -Compress)
    Write-RgLog 'evaluator-change' ([ordered]@{ provider = $Provider; model = $Model })
    return (Read-RgEvaluatorChoice)
}

# Nhà cung cấp sẽ dùng: lựa chọn ở UI -> cfg.agents.evaluator.provider -> 'auto' (cái đầu tiên sẵn sàng theo thứ tự khai báo). $null nếu không có cái nào.
# Kết quả được nhớ 30 giây (dò PATH + thử cổng cục bộ tốn 0,1-0,4 giây; báo cáo trợ lý gọi hàm này mỗi lần UI hỏi). -NoCache: tính lại ngay.
$script:RgEvalMemo = $null
function Get-RgEvaluator($Cfg = $null, [switch]$NoCache) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $stamp = Get-RgFileStamp (Get-RgEvaluatorStatePath)
    $m = $script:RgEvalMemo
    if (-not $NoCache -and $m -and [object]::ReferenceEquals($m.cfg, $Cfg) -and $m.stamp -eq $stamp -and ((Get-Date) - $m.at).TotalSeconds -lt 30) { return $m.value }
    $v = Get-RgEvaluatorUncached $Cfg
    $script:RgEvalMemo = @{ cfg = $Cfg; stamp = $stamp; at = (Get-Date); value = $v }
    return $v
}
function Get-RgEvaluatorUncached($Cfg) {
    $all = @(Get-RgProviders $Cfg)
    $choice = Read-RgEvaluatorChoice
    $want = [string]$choice.provider; $model = [string]$choice.model
    if (-not $want) { try { if ($Cfg.agents.evaluator.provider) { $want = [string]$Cfg.agents.evaluator.provider } } catch { } }
    if (-not $model) { try { if ($Cfg.agents.evaluator.model) { $model = [string]$Cfg.agents.evaluator.model } } catch { } }
    $pick = $null
    if ($want -and $want -ne 'auto') { $pick = @($all | Where-Object { $_.id -eq $want }) | Select-Object -First 1; if ($pick -and -not (Test-RgProviderReady $pick).ok) { $pick = $null } }
    else { foreach ($p in $all) { if ((Test-RgProviderReady $p).ok) { $pick = $p; break } } }
    if (-not $pick) { return $null }
    if ($model -and $want -and $want -ne 'auto') { $pick = $pick.PSObject.Copy(); $pick.model = $model }   # model chọn tay chỉ áp cho đúng nhà cung cấp đã chọn tay
    return $pick
}

# Khối JSON đầu tiên trong văn bản (model hay bọc ```json ... ``` hoặc viết thêm lời dẫn). $null nếu không có.
function Get-RgFirstJsonObject([string]$Text) {
    if (-not $Text) { return $null }
    $start = $Text.IndexOf('{')
    while ($start -ge 0) {
        $depth = 0; $inStr = $false; $esc = $false
        for ($i = $start; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($inStr) { if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }; continue }
            if ($ch -eq '"') { $inStr = $true } elseif ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $cand = $Text.Substring($start, $i - $start + 1); try { [void](ConvertFrom-Json $cand); return $cand } catch { break } } }
        }
        $start = $Text.IndexOf('{', $start + 1)
    }
    return $null
}

# Kiểm một giá trị với JSON schema tối thiểu (type, properties, required, enum, items). Trả '' nếu hợp lệ, không thì câu mô tả lỗi đầu tiên.
# Đây là chốt chung cho MỌI nhà cung cấp: cái nào không ép được schema thì kết quả sai dạng bị loại ở đây.
function Test-RgJsonShape($Value, $Schema, [string]$Path = '$') {
    $t = [string]$Schema.type
    switch ($t) {
        'object' {
            if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { return "$Path phải là object" }
            foreach ($r in @($Schema.required)) { if ($r -and -not $Value.PSObject.Properties[[string]$r]) { return "$Path thiếu '$r'" } }
            if ($Schema.properties) {
                foreach ($p in $Schema.properties.PSObject.Properties) {
                    if (-not $Value.PSObject.Properties[$p.Name]) { continue }
                    $e = Test-RgJsonShape $Value.($p.Name) $p.Value "$Path.$($p.Name)"; if ($e) { return $e }
                }
            }
        }
        'array' {
            if ($null -eq $Value) { return '' }   # PS 5.1: mảng rỗng có thể thành $null sau ConvertFrom-Json
            $i = 0
            foreach ($it in @($Value)) { if ($Schema.items) { $e = Test-RgJsonShape $it $Schema.items "$Path[$i]"; if ($e) { return $e } }; $i++; if ($i -gt 500) { return "$Path quá dài" } }
        }
        'string' { if ($Value -isnot [string]) { return "$Path phải là chuỗi" } }
        'integer' { if ($Value -isnot [int] -and $Value -isnot [long]) { $d = 0.0; if (-not ($Value -is [double] -or $Value -is [decimal]) -or [math]::Floor([double]$Value) -ne [double]$Value) { return "$Path phải là số nguyên" } } }
        'number' { if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return "$Path phải là số" } }
        'boolean' { if ($Value -isnot [bool]) { return "$Path phải là true/false" } }
    }
    if ($Schema.PSObject.Properties['enum'] -and $Schema.enum -and (@($Schema.enum) -cnotcontains $Value)) { return "$Path có giá trị ngoài danh sách cho phép" }
    return ''
}

# POST JSON, đọc phản hồi dạng UTF-8 (Invoke-RestMethod của PS 5.1 giải mã sai tiếng Việt khi server không khai charset). Ném lỗi kèm mã HTTP.
function Invoke-RgHttpJson([string]$Url, [string]$Body, $Headers = @{}, [int]$TimeoutSec = 120, [string]$Method = 'POST') {
    if ($Url -match '^https:') { try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { } }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method; $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000; $req.Accept = 'application/json'; $req.UserAgent = 'resource-guard'
    foreach ($k in $Headers.Keys) { $req.Headers[[string]$k] = [string]$Headers[$k] }
    if ($Method -ne 'GET') {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Body)
        $req.ContentType = 'application/json; charset=utf-8'; $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream(); try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Dispose() }
    }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] {
        $r = $_.Exception.Response; $detail = ''
        if ($r) { try { $detail = (New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } catch { }; $code = [int]$r.StatusCode; $r.Close(); if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }; throw "HTTP $code từ nhà cung cấp: $detail" }
        throw ('Không gọi được nhà cung cấp: ' + $_.Exception.Message)
    }
    try { return (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } finally { $resp.Close() }
}

# Gọi nhà cung cấp, trả { data; provider; model; costUsd; durationMs; bytes; local }. `data` đã qua Test-RgJsonShape. Ném lỗi có câu tiếng Việt.
# Prompt chỉ chứa metadata do nơi gọi dựng; hàm này không thêm dữ liệu máy nào.
function Invoke-RgLlmJson {
    param([string]$Prompt, [string]$Schema, $Provider = $null, [int]$TimeoutSec = 180, [double]$MaxBudgetUsd = 0.5, [string]$Effort = 'high', [string]$Model = '')
    if (-not $Provider) { $Provider = Get-RgEvaluator }
    if (-not $Provider) { throw 'Chưa có nhà cung cấp AI nào dùng được (cần một trong: claude, codex, gemini trong PATH; Ollama đang chạy; hoặc API tương thích OpenAI đã khai trong config).' }
    $P = $Provider
    $mdl = $(if ($Model) { $Model } else { [string]$P.model })
    $schemaObj = ConvertFrom-Json $Schema
    $text = $Prompt
    if ($P.schemaInPrompt -or ($P.type -eq 'http' -and $P.api -eq 'openai' -and [string]$P.responseFormat -ne 'json_schema')) {
        $text += "`n`nTRẢ LỜI: chỉ in DUY NHẤT một đối tượng JSON hợp lệ theo JSON Schema dưới đây, không kèm lời dẫn hay markdown.`n" + $Schema
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $raw = ''; $cost = $null; $data = $null
    if ($P.type -eq 'cli') {
        $cli = Resolve-RgCli ([string]$P.command)
        if (-not $cli) { throw "Không tìm thấy lệnh '$($P.command)' trong PATH." }
        $cwd = Join-Path (Initialize-RgHome) 'state\agent-cwd'
        [void](New-Item -ItemType Directory -Force -Path $cwd)
        $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $schemaFile = Join-Path $cwd "schema-$tag.json"; $outFile = Join-Path $cwd "out-$tag.txt"; $promptFile = Join-Path $cwd "prompt-$tag.txt"
        $enc = New-Object Text.UTF8Encoding($false)
        try {
            $tpl = [string]$P.args
            if ($tpl.Contains('{schemaFile}')) { [IO.File]::WriteAllText($schemaFile, $Schema, $enc) }
            if ($tpl.Contains('{promptFile}')) { [IO.File]::WriteAllText($promptFile, $text, $enc) }
            $modelArg = $(if ($mdl -and $P.modelFlag) { "$($P.modelFlag) $mdl" } else { '' })
            $a = $tpl.Replace('{model}', $mdl).Replace('{modelArg}', $modelArg).Replace('{effort}', $(if ($Effort) { $Effort } else { 'high' })).Replace('{budget}', $MaxBudgetUsd.ToString([Globalization.CultureInfo]::InvariantCulture))
            $a = $a.Replace('{schemaFile}', $schemaFile).Replace('{outFile}', $outFile).Replace('{promptFile}', $promptFile).Replace('{schemaInline}', $Schema.Replace('"', '\"'))
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $cli.file; $psi.Arguments = ([string]$cli.prefix + $a.Trim() + $(if ($cli.PSObject.Properties['suffix']) { [string]$cli.suffix } else { '' })); $psi.WorkingDirectory = $cwd
            $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            $proc = [Diagnostics.Process]::Start($psi)
            $outT = $proc.StandardOutput.ReadToEndAsync(); $errT = $proc.StandardError.ReadToEndAsync()
            try { $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $proc.StandardInput.BaseStream.Flush() } catch { }
            try { $proc.StandardInput.Close() } catch { }
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) { try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }; throw "$($P.label) không trả lời sau $TimeoutSec giây (đã dừng)." }
            $out = [string]$outT.Result; $err = [string]$errT.Result
            if ($P.parse -eq 'claude') {
                $res = $null
                try { $res = ConvertFrom-Json $out } catch { $both = ($err + ' ' + $out).Trim(); throw ("Không đọc được JSON từ $($P.label) (exit $($proc.ExitCode)): " + $both.Substring(0, [math]::Min(300, $both.Length))) }
                if ($res.is_error -or -not $res.structured_output) { throw ("$($P.label) báo lỗi: " + [string]$res.result) }
                $data = $res.structured_output; $cost = $res.total_cost_usd
            } else {
                if (Test-Path -LiteralPath $outFile) { $raw = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }
                if (-not $raw.Trim()) { $raw = $out }
                if ($P.parse -eq 'gemini') { try { $g = ConvertFrom-Json $out; if ($g.PSObject.Properties['response'] -and $g.response) { $raw = [string]$g.response } elseif ($g.PSObject.Properties['error'] -and $g.error) { throw ("$($P.label) báo lỗi: " + [string]$g.error.message) } } catch [System.ArgumentException] { } }
                if (-not $raw.Trim()) { $e2 = $err.Trim(); throw ("$($P.label) không trả kết quả (exit $($proc.ExitCode))" + $(if ($e2) { ': ' + $e2.Substring(0, [math]::Min(300, $e2.Length)) } else { '.' })) }
            }
        } finally { foreach ($f in $schemaFile, $outFile, $promptFile) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    } else {
        $hdr = @{}
        if ($P.apiKeyEnv) { $key = [Environment]::GetEnvironmentVariable([string]$P.apiKeyEnv); if ($key) { $hdr['Authorization'] = 'Bearer ' + $key } elseif (-not $P.local) { throw "Chưa có biến môi trường $($P.apiKeyEnv)." } }
        if ($P.api -eq 'ollama') {
            if (-not $mdl) {   # chưa khai model: lấy model đầu tiên máy chủ Ollama đang có
                $tags = ConvertFrom-Json (Invoke-RgHttpJson ($P.baseUrl + '/api/tags') '' $hdr 10 'GET')
                $mdl = [string](@($tags.models | ForEach-Object { $_ }) | Select-Object -First 1).name
                if (-not $mdl) { throw 'Ollama chưa có model nào. Tải một model (vd. `ollama pull qwen2.5:7b`) rồi thử lại.' }
            }
            $body = '{"model":' + (ConvertTo-Json $mdl) + ',"stream":false,"options":{"temperature":0},"format":' + $Schema + ',"messages":[{"role":"user","content":' + (ConvertTo-Json $text) + '}]}'
            $resp = ConvertFrom-Json (Invoke-RgHttpJson ($P.baseUrl + '/api/chat') $body $hdr $TimeoutSec)
            $raw = [string]$resp.message.content
        } else {
            if (-not $mdl) { throw "Chưa khai model cho '$($P.id)' (agents.providers.$($P.id).model)." }
            $rf = ''
            if ([string]$P.responseFormat -eq 'json_schema') { $rf = ',"response_format":{"type":"json_schema","json_schema":{"name":"resource_guard","strict":true,"schema":' + $Schema + '}}' }
            elseif ([string]$P.responseFormat -eq 'json_object') { $rf = ',"response_format":{"type":"json_object"}' }
            $body = '{"model":' + (ConvertTo-Json $mdl) + $rf + ',"messages":[{"role":"user","content":' + (ConvertTo-Json $text) + '}]}'
            $resp = ConvertFrom-Json (Invoke-RgHttpJson ($P.baseUrl + '/chat/completions') $body $hdr $TimeoutSec)
            $raw = [string](@($resp.choices | ForEach-Object { $_ }) | Select-Object -First 1).message.content
        }
        if (-not $raw.Trim()) { throw "$($P.label) trả về nội dung rỗng." }
    }
    if ($null -eq $data) {
        $js = Get-RgFirstJsonObject $raw
        if (-not $js) { throw "$($P.label) không trả về JSON đọc được." }
        $data = ConvertFrom-Json $js
    }
    $bad = Test-RgJsonShape $data $schemaObj
    if ($bad) { throw "$($P.label) trả kết quả sai dạng ($bad); đã bỏ." }
    return [pscustomobject]@{ data = $data; provider = [string]$P.id; label = [string]$P.label; model = $mdl; costUsd = $cost; durationMs = [long]$sw.ElapsedMilliseconds; bytes = $bytes.Length; local = [bool]$P.local }
}

# Thử một nhà cung cấp bằng câu hỏi nhỏ KHÔNG kèm dữ liệu máy. Trả { ok; provider; model; durationMs; error }.
function Test-RgProviderCall([string]$Id) {
    $p = @(Get-RgProviders | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $p) { return [ordered]@{ ok = $false; provider = $Id; error = "Không có nhà cung cấp '$Id'." } }
    $rdy = Test-RgProviderReady $p
    if (-not $rdy.ok) { return [ordered]@{ ok = $false; provider = $Id; error = $rdy.reason } }
    try {
        $r = Invoke-RgLlmJson -Prompt 'Đây là phép thử kết nối. Trả về JSON có trường "ok" = true và "note" là một câu chào ngắn bằng tiếng Việt.' -Schema '{"type":"object","additionalProperties":false,"properties":{"ok":{"type":"boolean"},"note":{"type":"string"}},"required":["ok","note"]}' -Provider $p -TimeoutSec 90 -MaxBudgetUsd 0.05 -Effort 'low'
        return [ordered]@{ ok = $true; provider = $Id; model = $r.model; durationMs = $r.durationMs; note = [string]$r.data.note }
    } catch { return [ordered]@{ ok = $false; provider = $Id; error = [string]$_.Exception.Message } }
}

# ---------- 3. Hook nhiều agent: chuẩn hoá về dạng chung (tên sự kiện/trường theo Claude Code, vì Invoke-RgHookEvent đã dùng dạng đó) ----------

# Mỗi bảng: events (tên của agent -> tên chuẩn), trường session/cwd/tool/command (đường dẫn dấu chấm), tên tool là subagent / shell,
# reply = cách báo chặn ('exit2': mã thoát 2 + stderr; 'cursor': JSON { permission } ở stdout). `verified` = đã đo trên máy thật.
$script:RgHookMaps = @{
    claude = @{ verified = $true; reply = 'exit2'; events = @{}; session = 'session_id'; cwd = 'cwd'; tool = 'tool_name'; command = 'tool_input.command'; toolUseId = 'tool_use_id'
        subagentTools = @('Task', 'Agent'); shellTools = @('Bash', 'PowerShell') }
    gemini = @{ verified = $false; reply = 'exit2'; events = @{ BeforeTool = 'PreToolUse'; AfterTool = 'PostToolUse'; BeforeAgent = 'UserPromptSubmit'; AfterAgent = 'Stop' }
        session = 'session_id'; cwd = 'cwd'; tool = 'tool_name'; command = 'tool_input.command'; toolUseId = 'tool_use_id'; subagentTools = @(); shellTools = @('run_shell_command') }
    cursor = @{ verified = $false; reply = 'cursor'; events = @{ beforeShellExecution = 'PreToolUse'; afterShellExecution = 'PostToolUse'; beforeSubmitPrompt = 'UserPromptSubmit'; stop = 'Stop'; sessionStart = 'SessionStart'; sessionEnd = 'SessionEnd' }
        session = 'conversation_id'; cwd = 'workspace_roots'; tool = ''; command = 'command'; toolUseId = 'generation_id'; subagentTools = @(); shellTools = @(); shellEvents = @('beforeShellExecution', 'afterShellExecution') }
}

function Get-RgHookMap([string]$Agent, $Cfg = $null) {
    $id = ([string]$Agent).ToLowerInvariant()
    try { if (-not $Cfg) { $Cfg = Get-RgConfig }; $a = @(Get-RgAgentCatalog $Cfg | Where-Object { $_.id -eq $id }) | Select-Object -First 1; if ($a -and $a.hooks) { $id = [string]$a.hooks } } catch { }
    if ($script:RgHookMaps.ContainsKey($id)) { return $script:RgHookMaps[$id] }
    return $script:RgHookMaps['claude']   # agent lạ: coi như gửi đúng dạng chuẩn
}

function Get-RgDotted($Obj, [string]$Path) {
    $cur = $Obj
    foreach ($seg in ($Path -split '\.')) { if ($null -eq $cur -or -not $seg) { return $null }; $p = $cur.PSObject.Properties[$seg]; if (-not $p) { return $null }; $cur = $p.Value }
    return $cur
}

# Payload thô của một agent -> payload chuẩn { hook_event_name, session_id, cwd, source, tool_name ('Task' | 'Bash' | tên gốc), tool_input.command, tool_use_id }.
function ConvertTo-RgHookPayload($Raw, [string]$Agent = 'claude', $Cfg = $null) {
    $m = Get-RgHookMap $Agent $Cfg
    $evRaw = [string]$Raw.hook_event_name
    $ev = $(if ($m.events.ContainsKey($evRaw)) { [string]$m.events[$evRaw] } else { $evRaw })
    $cwd = Get-RgDotted $Raw ([string]$m.cwd); if ($cwd -is [array]) { $cwd = @($cwd)[0] }
    $tool = $(if ($m.tool) { [string](Get-RgDotted $Raw ([string]$m.tool)) } else { '' })
    $std = $tool
    if (@($m.subagentTools) -contains $tool) { $std = 'Task' }
    elseif (@($m.shellTools) -contains $tool) { $std = 'Bash' }
    elseif ($m.ContainsKey('shellEvents') -and @($m.shellEvents) -contains $evRaw) { $std = 'Bash' }
    return [pscustomobject][ordered]@{
        hook_event_name = $ev; session_id = [string](Get-RgDotted $Raw ([string]$m.session)); cwd = [string]$cwd; source = [string]$Raw.source
        tool_name = $std; tool_input = [pscustomobject]@{ command = [string](Get-RgDotted $Raw ([string]$m.command)) }; tool_use_id = [string](Get-RgDotted $Raw ([string]$m.toolUseId))
    }
}

# ---------- 4. Lời gọi từ agent (dùng chung cho MCP và HTTP). Chỉ đọc + tư vấn + lease/giữ chỗ. ----------

function Hide-RgUserPath([string]$Path) {
    $h = [string]$env:USERPROFILE
    if ($h -and $Path -and $Path.StartsWith($h, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $Path.Substring($h.Length) }
    return $Path
}

$script:RgAgentTools = @(
    [ordered]@{ name = 'resource_status'; description = 'Trạng thái tài nguyên của máy Windows này (RAM, bộ nhớ cam kết, ổ đĩa) và mức chung: Normal | Caution | Restricted | Critical. Gọi trước khi làm việc nặng. / Current machine resource state.'
        inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{}; additionalProperties = $false } },
    [ordered]@{ name = 'preflight'; description = 'Hỏi trước khi chạy tác vụ nặng: build, test hoặc tạo subagent. Trả decision allow | warn | deny kèm lý do; nếu không bị từ chối thì giữ chỗ RAM để các tác vụ song song không cùng chiếm. Bị deny thì KHÔNG chạy, chờ rồi hỏi lại. / Ask before a heavy build, test or subagent.'
        inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{ task = [ordered]@{ type = 'string'; enum = @('build', 'test', 'subagent') }; reserve = [ordered]@{ type = 'boolean'; description = 'Giữ chỗ (mặc định true)' } }; required = @('task'); additionalProperties = $false } },
    [ordered]@{ name = 'release'; description = 'Nhả giữ chỗ của một tác vụ đã xong (build/test/subagent). Gọi sau khi tác vụ kết thúc. / Release a finished reservation.'
        inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{ task = [ordered]@{ type = 'string'; enum = @('build', 'test', 'subagent') } }; required = @('task'); additionalProperties = $false } },
    [ordered]@{ name = 'cleanup_candidates'; description = 'Danh sách mục có thể dọn mà Resource Guard đã quét (chỉ đọc, đường dẫn đã rút gọn). Agent KHÔNG được tự xoá: hãy đề xuất cho người dùng dọn trong giao diện Resource Guard. / Read-only list of cleanup candidates.'
        inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{ limit = [ordered]@{ type = 'integer'; minimum = 1; maximum = 50 } }; additionalProperties = $false } },
    [ordered]@{ name = 'explain_process'; description = 'Giải thích một tiến trình theo PID: là gì, do ai mở, có nên kết thúc không (chỉ đọc). / Explain a process by PID.'
        inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{ pid = [ordered]@{ type = 'integer'; minimum = 5 } }; required = @('pid'); additionalProperties = $false } }
)
function Get-RgAgentToolList { return @($script:RgAgentTools) }

# Một lời gọi công cụ. $Session = @{ sessionId; agent; ownerPid; source }. Trả đối tượng kết quả; tham số sai thì ném lỗi (nơi gọi đổi thành lỗi giao thức).
function Invoke-RgAgentTool {
    param([string]$Name, $ToolArgs = $null, $Session = $null, [scriptblock]$SnapshotProvider = $null)
    $cfg = Get-RgConfig
    $sid = $(if ($Session) { [string]$Session.sessionId } else { '' })
    $arg = { param($n) if ($ToolArgs -and $ToolArgs.PSObject.Properties[$n]) { $ToolArgs.$n } else { $null } }
    $ensure = {
        if ($sid -and -not (Update-RgLeaseHeartbeat -SessionId $sid).ok) {
            [void](New-RgLease -SessionId $sid -Agent $(if ($Session.agent) { [string]$Session.agent } else { 'unknown' }) -OwnerPid ([int]$Session.ownerPid) -Cwd '' -Source $(if ($Session.source) { [string]$Session.source } else { 'api' }))
        }
    }
    switch ($Name) {
        'resource_status' {
            $snap = $null; $table = $null
            if ($SnapshotProvider) { $sp = & $SnapshotProvider; $snap = $sp.snapshot; $table = $sp.table } else { $snap = Get-RgSnapshot -SkipCpu -Fast; $table = @(Get-RgProcessTable) }
            $b = Get-RgBudget -Task 'session' -Snapshot $snap -Table $table
            return [ordered]@{ state = $b.state; availRamGB = $snap.availRamGB; totalRamGB = $snap.totalRamGB; commitPct = $snap.commitPct
                drives = @($snap.drives | Where-Object { $_ } | ForEach-Object { [ordered]@{ drive = $_.drive; freeGB = $_.freeGB; totalGB = $_.totalGB; state = $_.state } })
                heavyRunning = $b.heavyRunning; maxHeavy = $b.maxHeavy; reasons = @($b.reasons)
                advice = $(switch ([string]$b.state) { 'Normal' { 'Máy đang ổn.' } 'Caution' { 'Máy hơi chật: tránh chạy nhiều việc nặng cùng lúc.' } 'Restricted' { 'Máy đang chật: chỉ chạy một việc nặng, không tạo subagent.' } default { 'Máy nguy cấp: đừng bắt đầu build/test/subagent mới.' } }) }
        }
        'preflight' {
            $task = [string](& $arg 'task')
            if (@('build', 'test', 'subagent') -notcontains $task) { throw "task chỉ nhận 'build', 'test' hoặc 'subagent'." }
            $rv = & $arg 'reserve'; $reserve = ($null -eq $rv -or [bool]$rv)
            & $ensure
            $pf = Invoke-RgPreflight -Task $task -SessionId $sid -Reserve:$reserve -SnapshotProvider $SnapshotProvider
            Write-RgLog 'agent-preflight' ([ordered]@{ agent = $(if ($Session) { [string]$Session.agent } else { '' }); task = $task; decision = [string]$pf.decision; state = [string]$pf.state; source = $(if ($Session) { [string]$Session.source } else { '' }) })
            return [ordered]@{ task = $task; decision = [string]$pf.decision; state = [string]$pf.state; reasons = @($pf.reasons); reservationId = $pf.reservationId; warning = [string]$pf.warning
                instruction = $(if ([string]$pf.decision -eq 'deny') { "Chưa nên chạy '$task' lúc này. Hãy chờ hoặc đề nghị người dùng giải phóng bộ nhớ/ổ đĩa, rồi gọi preflight lại." } elseif ($reserve) { "Được chạy. Khi '$task' xong hãy gọi release." } else { 'Được chạy.' }) }
        }
        'release' {
            $task = [string](& $arg 'task')
            if (@('build', 'test', 'subagent') -notcontains $task) { throw "task chỉ nhận 'build', 'test' hoặc 'subagent'." }
            if (-not $sid) { return [ordered]@{ released = 0 } }
            $n = Remove-RgReservation -SessionId $sid -Task $task
            [void](Update-RgLeaseHeartbeat -SessionId $sid)
            return [ordered]@{ released = [int]$n }
        }
        'cleanup_candidates' {
            $lim = 15; $lv = & $arg 'limit'; if ($null -ne $lv) { $lim = [math]::Max(1, [math]::Min(50, [int]$lv)) }
            $p = Join-Path (Initialize-RgHome) 'state\scan-candidates.json'
            if (-not (Test-Path -LiteralPath $p)) { return [ordered]@{ scanned = $false; items = @(); note = 'Chưa quét. Người dùng mở Resource Guard và bấm quét.' } }
            $cd = ConvertFrom-Json (Read-RgFileShared $p)
            $items = @($cd.items | ForEach-Object { $_ } | Where-Object { $_ -and $_.kind -ne 'process' -and $_.action -eq 'delete' } | Sort-Object { [long]$_.sizeBytes } -Descending | Select-Object -First $lim | ForEach-Object {
                    [ordered]@{ kind = [string]$_.kind; path = (Hide-RgUserPath ([string]$_.path)); sizeMB = [math]::Round([double]$_.sizeBytes / 1MB, 0); ageDays = $_.ageDays; risk = [string]$_.riskLevel; regen = [string]$_.regen } })
            return [ordered]@{ scanned = $true; finishedUtc = [string]$cd.finishedUtc; items = $items; note = 'Chỉ để tham khảo. Việc dọn do người dùng duyệt trong giao diện Resource Guard; đừng tự xoá các đường dẫn này.' }
        }
        'explain_process' {
            $procId = 0; if (-not [int]::TryParse([string](& $arg 'pid'), [ref]$procId) -or $procId -le 4) { throw 'pid không hợp lệ.' }
            if (-not (Get-Command Get-RgProcExplain -ErrorAction SilentlyContinue)) { throw 'Chức năng giải thích tiến trình chưa được nạp.' }
            $x = Get-RgProcExplain -ProcId $procId -Start '' -Cfg $cfg -Table @(Get-RgProcessTable)
            if (-not $x.ok) { return [ordered]@{ found = $false; pid = $procId; note = [string]$x.error } }
            return $x
        }
        default { throw "Không có công cụ '$Name'." }
    }
}

# Một thông điệp JSON-RPC của MCP -> đối tượng phản hồi ($null cho notification). $State (hashtable) giữ phiên giữa các lời gọi: sessionId, agent, ownerPid.
$script:RgMcpVersions = @('2025-06-18', '2025-03-26', '2024-11-05')
function Invoke-RgMcpMessage($Msg, $State, [scriptblock]$SnapshotProvider = $null) {
    $hasId = [bool]($Msg -and $Msg.PSObject.Properties['id'])
    $reply = { param($result) if ($hasId) { [ordered]@{ jsonrpc = '2.0'; id = $Msg.id; result = $result } } else { $null } }
    $fail = { param([int]$code, [string]$message) if ($hasId) { [ordered]@{ jsonrpc = '2.0'; id = $Msg.id; error = [ordered]@{ code = $code; message = $message } } } else { $null } }
    if (-not $Msg -or [string]$Msg.jsonrpc -ne '2.0' -or -not $Msg.PSObject.Properties['method']) { return (& $fail -32600 'Invalid Request') }
    $method = [string]$Msg.method
    switch ($method) {
        'initialize' {
            $want = ''; try { $want = [string]$Msg.params.protocolVersion } catch { }
            $ver = $(if ($script:RgMcpVersions -contains $want) { $want } else { $script:RgMcpVersions[0] })
            $client = ''; try { $client = ([string]$Msg.params.clientInfo.name).ToLowerInvariant() } catch { }
            $agent = 'unknown'
            foreach ($a in (Get-RgAgentCatalog)) { $keys = @($a.id) + @($(if ($a.mcpClient) { $a.mcpClient -split '\|' } else { @() })); foreach ($k in $keys) { if ($k -and $client -and $client.Contains(([string]$k).ToLowerInvariant())) { $agent = $a.id; break } }; if ($agent -ne 'unknown') { break } }
            $State.agent = $agent; $State.client = $client
            try { [void](New-RgLease -SessionId ([string]$State.sessionId) -Agent $agent -OwnerPid ([int]$State.ownerPid) -Cwd '' -Source 'mcp') } catch { }
            return (& $reply ([ordered]@{ protocolVersion = $ver; capabilities = [ordered]@{ tools = [ordered]@{ listChanged = $false } }
                        serverInfo = [ordered]@{ name = 'resource-guard'; version = (Get-RgVersion) }
                        instructions = 'Resource Guard quản lý RAM và ổ đĩa của máy này. Trước khi chạy build/test nặng hoặc tạo subagent hãy gọi `preflight`; bị deny thì chờ rồi hỏi lại. Xong việc gọi `release`. Không tự xoá file để giải phóng chỗ: dùng `cleanup_candidates` để đề xuất cho người dùng.' }))
        }
        'ping' { return (& $reply ([ordered]@{})) }
        'tools/list' { return (& $reply ([ordered]@{ tools = @(Get-RgAgentToolList) })) }
        'tools/call' {
            $name = ''; $targs = $null
            try { $name = [string]$Msg.params.name; $targs = $Msg.params.arguments } catch { }
            if (@($script:RgAgentTools | ForEach-Object { $_.name }) -notcontains $name) { return (& $fail -32602 "Unknown tool: $name") }
            try {
                $r = Invoke-RgAgentTool -Name $name -ToolArgs $targs -Session $State -SnapshotProvider $SnapshotProvider
                return (& $reply ([ordered]@{ content = @([ordered]@{ type = 'text'; text = (ConvertTo-Json -InputObject $r -Depth 6 -Compress) }); isError = $false }))
            } catch { return (& $reply ([ordered]@{ content = @([ordered]@{ type = 'text'; text = [string]$_.Exception.Message }); isError = $true })) }
        }
        default {
            if ($method -like 'notifications/*') { return $null }
            return (& $fail -32601 "Method not found: $method")
        }
    }
}

# ---------- 5. Hướng dẫn kết nối (chỉ IN; không bao giờ tự sửa file cấu hình của người dùng) ----------

function Get-RgMcpCommand([string]$Root) {
    return [pscustomobject]@{ command = 'powershell.exe'; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\rg-mcp.ps1')) }
}

$script:RgAgentRule = 'Máy này có Resource Guard (MCP server "resource-guard"). Trước khi chạy build/test nặng hoặc tạo subagent, gọi công cụ `preflight`; nếu bị deny thì chờ rồi hỏi lại, xong việc gọi `release`. Không tự xoá file để giải phóng ổ đĩa: gọi `cleanup_candidates` rồi đề xuất cho người dùng.'

# Các bước kết nối cho một agent: { id; label; verified; steps = [{ title; file; lang; text; note }] }.
function Get-RgConnectGuide([string]$AgentId, [string]$Root, [switch]$Heavy) {
    $cat = @(Get-RgAgentCatalog)
    $a = @($cat | Where-Object { $_.id -eq ([string]$AgentId).ToLowerInvariant() }) | Select-Object -First 1
    if (-not $a) { throw ("Không có agent '$AgentId'. Có: " + (@($cat | ForEach-Object { $_.id }) -join ', ')) }
    $mc = Get-RgMcpCommand $Root
    $q = { param($s) '"' + ([string]$s).Replace('\', '\\').Replace('"', '\"') + '"' }   # chuỗi JSON: escape \ và "
    $argsJson = '[' + (@($mc.args | ForEach-Object { & $q $_ }) -join ', ') + ']'
    $mcpJson = "{`n  `"mcpServers`": {`n    `"resource-guard`": { `"command`": `"$($mc.command)`", `"args`": $argsJson }`n  }`n}"
    $hookCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Root 'scripts\rg-hook.ps1') + '" -Agent ' + $a.id
    $steps = @()
    $connect = @($a.connect)
    if ($connect -contains 'mcp') {
        switch ($a.id) {
            'claude' { $steps += [ordered]@{ title = 'MCP: chạy một lệnh'; file = ''; lang = 'powershell'; text = ('claude mcp add --scope user resource-guard -- ' + $mc.command + ' ' + (@($mc.args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')); note = 'Thêm MCP server cho mọi dự án của bạn.' } }
            'codex' { $steps += [ordered]@{ title = 'MCP: thêm vào config.toml'; file = '~\.codex\config.toml'; lang = 'toml'; text = ("[mcp_servers.resource-guard]`ncommand = `"$($mc.command)`"`nargs = $argsJson"); note = '' } }
            'vscode' { $steps += [ordered]@{ title = 'MCP: thêm vào mcp.json'; file = '.vscode\mcp.json (hoặc lệnh “MCP: Open User Configuration”)'; lang = 'json'; text = "{`n  `"servers`": {`n    `"resource-guard`": { `"type`": `"stdio`", `"command`": `"$($mc.command)`", `"args`": $argsJson }`n  }`n}"; note = 'Dùng cho Copilot Chat (agent mode). Cline/Roo: dán khối mcpServers ở dưới vào phần cài đặt MCP của tiện ích.' }
                $steps += [ordered]@{ title = 'MCP: dạng mcpServers (Cline, Roo…)'; file = ''; lang = 'json'; text = $mcpJson; note = '' } }
            default {
                $file = switch ($a.id) { 'gemini' { '~\.gemini\settings.json' } 'cursor' { '~\.cursor\mcp.json' } 'windsurf' { '~\.codeium\windsurf\mcp_config.json' } 'copilot' { '~\.copilot\mcp-config.json' } default { 'file cấu hình MCP của ' + $a.label } }
                $steps += [ordered]@{ title = 'MCP: gộp khối mcpServers'; file = $file; lang = 'json'; text = $mcpJson; note = '' }
            }
        }
        $steps += [ordered]@{ title = 'Nhắc agent dùng công cụ'; file = 'file quy tắc của agent (CLAUDE.md, AGENTS.md, GEMINI.md, .cursor/rules…)'; lang = 'text'; text = $script:RgAgentRule; note = 'MCP chỉ cung cấp công cụ; dòng này bảo agent gọi nó đúng lúc.' }
    }
    if ($connect -contains 'hooks') {
        switch ([string]$a.hooks) {
            'claude' { $steps += [ordered]@{ title = 'Hook (chặn chắc chắn, không phụ thuộc model)'; file = '~\.claude\settings.json'; lang = 'json'; text = (Get-RgHooksSnippet $Root -Heavy:$Heavy); note = 'Gộp khối "hooks" vào file. Hook tự chặn subagent' + $(if ($Heavy) { '/build/test' } else { '' }) + ' khi máy cạn tài nguyên.' } }
            'gemini' {
                $h = "{`n  `"hooks`": {`n    `"SessionStart`": [ { `"hooks`": [ { `"type`": `"command`", `"command`": $(& $q $hookCmd) } ] } ],`n    `"SessionEnd`": [ { `"hooks`": [ { `"type`": `"command`", `"command`": $(& $q $hookCmd) } ] } ],`n    `"BeforeTool`": [ { `"matcher`": `"run_shell_command`", `"hooks`": [ { `"type`": `"command`", `"command`": $(& $q $hookCmd), `"timeout`": 45000 } ] } ],`n    `"AfterTool`": [ { `"matcher`": `"run_shell_command`", `"hooks`": [ { `"type`": `"command`", `"command`": $(& $q $hookCmd) } ] } ]`n  }`n}"
                $steps += [ordered]@{ title = 'Hook (tuỳ chọn)'; file = '~\.gemini\settings.json'; lang = 'json'; text = $h; note = 'Theo tài liệu hook của Gemini CLI; CHƯA đo trên máy thật. Nếu bản Gemini CLI của bạn khác, chỉ dùng MCP ở trên.' }
            }
            'cursor' {
                $h = "{`n  `"version`": 1,`n  `"hooks`": {`n    `"beforeShellExecution`": [ { `"command`": $(& $q $hookCmd) } ],`n    `"afterShellExecution`": [ { `"command`": $(& $q $hookCmd) } ],`n    `"stop`": [ { `"command`": $(& $q $hookCmd) } ]`n  }`n}"
                $steps += [ordered]@{ title = 'Hook (tuỳ chọn)'; file = '~\.cursor\hooks.json'; lang = 'json'; text = $h; note = 'Theo tài liệu hook của Cursor; CHƯA đo trên máy thật.' }
            }
        }
    }
    if ($connect -contains 'wrapper') {
        $steps += [ordered]@{ title = 'Bọc lệnh (cho agent không có MCP lẫn hook)'; file = ''; lang = 'powershell'; text = ('rguard wrap -Agent ' + $a.id + ' -- ' + $(if ($a.cli) { $a.cli } else { '<lệnh của bạn>' })); note = 'Resource Guard ghi nhận phiên trong lúc lệnh chạy: tiến trình build/test của phiên được nhận đúng chủ.' }
    }
    $verified = ($a.id -eq 'claude')
    return [ordered]@{ id = $a.id; label = $a.label; verified = $verified; note = [string]$a.note
        status = $(if ($verified) { 'Đã kiểm trên máy thật.' } else { 'MCP server đã kiểm bằng client thử theo đúng giao thức; chưa chạy cùng ' + $a.label + ' thật trên máy phát triển.' })
        steps = @($steps) }
}

# Bức tranh cho UI: từng agent trong danh mục (đã cài? đang chạy? đang giữ lease?) + nhà cung cấp đánh giá. $Table = bảng tiến trình (có thể $null).
$script:RgCliProbe = @{}; $script:RgCliProbeAt = [datetime]::MinValue
function Get-RgAgentsView($Cfg = $null, $Table = $null) {
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    if (((Get-Date) - $script:RgCliProbeAt).TotalSeconds -ge 60) { $script:RgCliProbe = @{}; $script:RgCliProbeAt = Get-Date }
    $leases = @(); try { $leases = @(Get-RgLeases $Cfg) } catch { }
    $running = @{}
    foreach ($t in @($Table)) { if (-not $t) { continue }; $a = Get-RgAgentOf ([string]$t.Name) ([string]$t.Cmd) $Cfg; if ($a) { $running[$a.id] = 1 + [int]$running[$a.id] } }
    $agents = @(Get-RgAgentCatalog $Cfg | ForEach-Object {
            $inst = $null
            if ($_.cli) { if (-not $script:RgCliProbe.ContainsKey($_.cli)) { $script:RgCliProbe[$_.cli] = [bool](Get-Command $_.cli -ErrorAction SilentlyContinue) }; $inst = [bool]$script:RgCliProbe[$_.cli] }
            $id = $_.id
            $mine = @($leases | Where-Object { [string]$_.agent -eq $id })
            [ordered]@{ id = $id; label = $_.label; kind = $_.kind; installed = $inst; running = [int]$running[$id]; sessions = $mine.Count
                lastSeenUtc = [string](@($mine | Sort-Object { [string]$_.lastSeenUtc } -Descending | Select-Object -First 1).lastSeenUtc); via = @($mine | ForEach-Object { ([string]$_.source -split ':')[0] } | Select-Object -Unique)
                connect = @($_.connect); note = $_.note }
        })
    $ev = Get-RgEvaluator $Cfg; $choice = Read-RgEvaluatorChoice
    $provs = @(Get-RgProviders $Cfg | ForEach-Object {
            $r = Test-RgProviderReady $_
            [ordered]@{ id = $_.id; label = $_.label; type = $_.type; local = [bool]$_.local; ready = [bool]$r.ok; reason = [string]$r.reason; model = [string]$_.model; verified = [bool]$_.verified
                target = $(if ($_.type -eq 'http') { try { ([uri]$_.baseUrl).Host } catch { '' } } else { [string]$_.command }) }
        })
    return [ordered]@{ agents = $agents; providers = $provs; evaluator = $(if ($ev) { [ordered]@{ id = $ev.id; label = $ev.label; model = [string]$ev.model; local = [bool]$ev.local } } else { $null })
        choice = [ordered]@{ provider = $(if ($choice.provider) { $choice.provider } else { 'auto' }); model = $choice.model } }
}
