# hook-probe.ps1 - SPIKE (C1): Claude Code gọi hook lifecycle thế nào trên máy này? (sự kiện nào, JSON stdin có trường gì)
# KHÔNG sửa ~/.claude/settings.json. Tạo settings TẠM trong %TEMP%, chạy MỘT lần `claude -p` rất ngắn (model haiku, không tool) với --settings file tạm,
# hook chỉ ghi stdin vào file log tạm. Gửi đi chỉ có prompt cố định "ok" (không chứa dữ liệu người dùng/dự án). Xoá hết khi xong.
# Kết quả JSON: { claudeFound, ran, exitCode, events[{name, fields[]}], ... }. Không có `claude`/lỗi mạng là KẾT QUẢ HỢP LỆ: luôn thoát 0.
#   -NoRun : không gọi claude, chỉ in snippet hooks mẫu (cùng nội dung `rg.ps1 hooks print` sẽ in ở C3).
[CmdletBinding()]
param([switch]$Json, [switch]$NoRun, [int]$TimeoutSec = 90)
$ErrorActionPreference = 'Stop'
$out = [ordered]@{ claudeFound = $false; codexFound = [bool](Get-Command codex -ErrorAction SilentlyContinue); ran = $false }
$dir = Join-Path ([IO.Path]::GetTempPath()) ('rg-hook-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Force -Path $dir)
try {
    $log = Join-Path $dir 'events.jsonl'
    $hook = Join-Path $dir 'hook.ps1'
    # hook: đọc stdin (JSON), ghi 1 dòng vào log, thoát 0 (không chặn gì)
    [IO.File]::WriteAllText($hook, '$i=[Console]::In.ReadToEnd(); [IO.File]::AppendAllText(''' + $log + ''', $i.Replace("`r`n"," ").Replace("`n"," ") + "`n")' + "`r`nexit 0`r`n")
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hook + '"'
    $events = 'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'SubagentStop', 'Stop', 'SessionEnd'
    $h = [ordered]@{}
    foreach ($e in $events) { $h[$e] = @(@{ hooks = @(@{ type = 'command'; command = $cmd }) }) }
    $settings = Join-Path $dir 'settings.json'
    [IO.File]::WriteAllText($settings, (@{ hooks = $h } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $out.snippetEvents = $events
    $out.snippetExample = @{ hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'powershell.exe -NoProfile -File <script>' }) }) } }

    $cl = Get-Command claude -ErrorAction SilentlyContinue
    $out.claudeFound = [bool]$cl
    if ($cl -and -not $NoRun) {
        $out.claudeSource = $cl.Source
        $psi = New-Object Diagnostics.ProcessStartInfo
        # npm shim (.cmd/.ps1) cần cmd /c; chạy qua cmd để chắc chắn
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/c claude -p "ok" --model haiku --settings "' + $settings + '"'
        $psi.WorkingDirectory = $dir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; $out.timedOut = $true } else { $out.exitCode = $p.ExitCode }
        $out.ran = $true
        $out.stdoutLen = ([string]$so.Result).Length
        $errText = ([string]$se.Result).Trim(); if ($errText.Length -gt 200) { $errText = $errText.Substring(0, 200) }; $out.stderr = $errText
        Start-Sleep -Milliseconds 500
        $evs = @()
        if (Test-Path -LiteralPath $log) {
            foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8)) {
                if (-not $line.Trim()) { continue }
                try { $o = $line | ConvertFrom-Json } catch { $evs += [pscustomobject]@{ name = '(unparsable)'; fields = @() }; continue }
                $evs += [pscustomobject]@{ name = [string]$o.hook_event_name; fields = @($o.PSObject.Properties.Name); source = [string]$o.source; reason = [string]$o.reason }
            }
        }
        $out.events = $evs
        $out.eventNames = @($evs | ForEach-Object { $_.name })
        $out.hasSessionId = [bool]($evs | Where-Object { $_.fields -contains 'session_id' })
        $out.verdict = if ($evs.Count -gt 0) { 'hooks-fire' } else { 'no-events' }
    } elseif (-not $cl) { $out.verdict = 'claude-not-found' } else { $out.verdict = 'skipped' }
}
catch { $out.error = [string]$_.Exception.Message; $out.verdict = 'error' }
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
if ($Json) { $out | ConvertTo-Json -Depth 6 } else { $out.GetEnumerator() | ForEach-Object { '{0,-16} {1}' -f $_.Key, ($_.Value | ConvertTo-Json -Compress -Depth 4) } }
exit 0
