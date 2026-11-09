# rg-server.ps1 - chạy watcher + UI realtime trên http://localhost:<port>/ (chỉ nghe loopback).
#   rg-server.ps1                 # chạy foreground trong terminal, in URL, mở trình duyệt; Ctrl+C để dừng
#   rg-server.ps1 -Detach         # chạy ngầm (ẩn), in URL rồi trả terminal; dừng bằng rg-server.ps1 -Stop
#   rg-server.ps1 -Port 9000 -NoOpen -NoToast
# Giám sát realtime (SSE) + quản lý dọn dẹp: quét ổ đĩa, chính sách giữ/dọn, tự dọn nền, nhờ agent đánh giá.
# Mọi thao tác xoá/kill đi qua Invoke-RgApply (allowlist + revalidate); client chỉ gửi key, không gửi đường dẫn.
[CmdletBinding()]
param([int]$Port = 8765, [switch]$NoOpen, [switch]$NoToast, [switch]$Detach, [switch]$Stop, [switch]$Force)
$ErrorActionPreference = 'Stop'
$argNoToast = [bool]$NoToast; $argPort = $Port; $argNoOpen = [bool]$NoOpen; $argDetach = [bool]$Detach; $argStop = [bool]$Stop; $argForce = [bool]$Force
. (Join-Path $PSScriptRoot 'rg-watcher.ps1')   # nạp hàm (rg-watcher tự return khi bị dot-source)
. (Join-Path $PSScriptRoot 'rg-policy.ps1')
. (Join-Path $PSScriptRoot 'rg-agent.ps1')
$NoToast = [switch]$argNoToast; $Port = $argPort

$script:UiDir = Join-Path $PSScriptRoot '..\ui'
$script:InfoPath = Join-Path (Initialize-RgHome) 'state\server.json'

function Read-RgServerInfo {
    if (Test-Path -LiteralPath $script:InfoPath) {
        try { return (Get-Content -LiteralPath $script:InfoPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Get-RgLiveInfo {   # trả server.json chỉ khi process đó còn sống
    $i = Read-RgServerInfo
    if ($i -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue)) { return $i }
    return $null
}

# ---------- Stop / Detach (chạy ở process gọi, không vào server) ----------
if ($argStop) {
    $i = Get-RgLiveInfo
    if (-not $i) { Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue; 'Không có server đang chạy.'; return }
    $procId = [int]$i.pid
    $graceful = $false
    if (-not $argForce) {
        # Dừng êm qua API: đóng listener, nhả mutex, huỷ job chỉ-đọc. Từ chối nếu đang dọn/xoá dở.
        try {
            $r = Invoke-RestMethod -Method Post -Uri ($i.url + 'api/shutdown') -Headers @{ 'X-RG-Client' = 'ui' } -ContentType 'application/json' -Body '{}' -TimeoutSec 5
            $graceful = [bool]$r.ok
        } catch {
            $body = $null
            try { $body = ConvertFrom-Json ([string]$_.ErrorDetails.Message) } catch { }
            if ($body -and $body.busy) { "Chưa dừng: $($body.error) Chờ xong rồi chạy lại, hoặc dùng -Force để buộc dừng."; return }
        }
        if ($graceful) {
            try { Wait-Process -Id $procId -Timeout 10 -ErrorAction Stop } catch { }
        }
    }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        $how = if ($argForce) { 'buộc dừng' } else { 'không phản hồi nên buộc dừng' }
    } else { $how = 'dừng êm' }
    Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue
    "Đã dừng Resource Guard ($how, pid $procId)."
    return
}

$existing = Get-RgLiveInfo
if ($existing) {
    "Resource Guard đã chạy: $($existing.url)  (pid $($existing.pid))"
    if (-not $argNoOpen -and -not $argDetach) { Start-Process $existing.url }
    return
}

if ($argDetach) {
    $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Port', $argPort, '-NoOpen')
    if ($argNoToast) { $a += '-NoToast' }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'   # 5.1: toast WinRT hoạt động
    if (-not (Test-Path $exe)) { $exe = (Get-Process -Id $PID).Path }
    [void](Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden)
    for ($k = 0; $k -lt 40; $k++) {
        Start-Sleep -Milliseconds 250
        $i = Get-RgLiveInfo
        if ($i) { "Resource Guard chạy ngầm: $($i.url)  (pid $($i.pid)). Dừng: nút ""Thoát Resource Guard"" trên giao diện, hoặc rg stop"; if (-not $argNoOpen) { Start-Process $i.url }; return }
    }
    throw 'Server không lên sau 10 giây; xem logs\rg-*.jsonl.'
}

# ---------- Helpers HTTP ----------

function Send-Bytes($Ctx, [int]$Status, [string]$Type, [byte[]]$Bytes) {
    $r = $Ctx.Response
    $r.StatusCode = $Status; $r.ContentType = $Type; $r.ContentLength64 = $Bytes.Length
    $r.Headers['Cache-Control'] = 'no-store'
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length); $r.OutputStream.Close()
}
function Send-Json($Ctx, $Obj, [int]$Status = 200) {
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Obj -Depth 6 -Compress)))
}

# Chống DNS-rebinding / CSRF: Host phải là loopback; POST phải có header tuỳ biến (buộc preflight CORS) và Origin (nếu có) cùng gốc.
function Test-RgRequestAllowed($Ctx, [int]$Port) {
    $req = $Ctx.Request
    $okHosts = @("localhost:$Port", "127.0.0.1:$Port")
    if ($okHosts -notcontains [string]$req.Headers['Host']) { return $false }
    if ($req.HttpMethod -ne 'GET') {
        if ($req.Headers['X-RG-Client'] -ne 'ui') { return $false }
        $o = [string]$req.Headers['Origin']
        if ($o -and (@("http://localhost:$Port", "http://127.0.0.1:$Port") -notcontains $o)) { return $false }
    }
    return $true
}

function Send-RawJson($Ctx, [string]$Json, [int]$Status = 200) {
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Json))
}

$script:StaticTypes = @{ '.css' = 'text/css; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.svg' = 'image/svg+xml' }

function Read-RgBody($Req) {
    if ($Req.ContentLength64 -gt 262144) { throw 'Body quá lớn.' }
    $b = (New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
    if (-not $b) { return $null }
    return (ConvertFrom-Json $b)
}

# Chạy script nền ở process riêng (server không bị chặn khi máy lag). Đường dẫn có dấu cách được bọc nháy.
function Start-RgJob([string]$Script, [string[]]$ScriptArgs = @()) {
    $exe = (Get-Process -Id $PID).Path
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot $Script) + '"')) + $ScriptArgs
    [void](Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden)
}

function Test-RgJobRunning([string]$File) {
    $j = Get-RgJobState $File
    return [bool]($j -and $j.status -eq 'running')
}

# Job chỉ-đọc (quét ổ, quét ứng viên, agent): huỷ cả cây tiến trình khi thoát. Job ghi (dọn/khôi phục/tự dọn) không bao giờ bị huỷ ở đây.
function Stop-RgReadOnlyJobs {
    foreach ($f in @('scan-breakdown.progress.json', 'scan-candidates.progress.json', 'agent.progress.json')) {
        $j = Get-RgJobState $f
        if (-not ($j -and $j.status -eq 'running' -and $j.pid)) { continue }
        $p = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
        if (-not $p -or @('pwsh', 'powershell') -notcontains $p.ProcessName) { continue }   # chống PID bị tái sử dụng
        & taskkill.exe /PID ([int]$j.pid) /T /F 2>&1 | Out-Null
        $j.status = 'error'; $j.message = 'đã huỷ vì Resource Guard thoát'
        try { Write-RgJobState $f $j } catch { }
    }
}

function Read-RgStateText([string]$Name) {
    $p = Join-Path (Initialize-RgHome) ("state\" + $Name)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Read-RgFileShared $p)
}

function Get-RgRecentEvents([int]$Max = 30) {
    $dir = Join-Path (Initialize-RgHome) 'logs'
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'rg-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 3)) {
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -Tail 400 -Encoding UTF8 | Where-Object { $_ -match '"event":"(state-change|would-kill-orphans|settings-change|watcher-start|server-start|auto-run|manual-cleanup|policy-change|agent-eval)"' })) {
            try { $out += ConvertFrom-Json $l } catch { }
        }
        if ($out.Count -ge $Max) { break }
    }
    return @($out | Sort-Object ts -Descending | Select-Object -First $Max)
}

function Get-RgThresholds {
    $c = Get-RgConfig
    return [ordered]@{
        ramAvailGB = [ordered]@{ normalAbove = $c.ram.normalAboveGB; cautionFrom = $c.ram.cautionFromGB; restrictedFrom = $c.ram.restrictedFromGB }
        diskFreeGB = [ordered]@{ normalAbove = $c.disk.normalAboveGB; cautionFrom = $c.disk.cautionFromGB }
        commitPct  = [ordered]@{ restricted = $c.commit.restrictedPct; critical = $c.commit.criticalPct }
    }
}

function Send-RgSse($Clients, [string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    foreach ($c in @($Clients.ToArray())) {
        try { $c.OutputStream.Write($bytes, 0, $bytes.Length); $c.OutputStream.Flush() }
        catch { [void]$Clients.Remove($c); try { $c.Close() } catch { } }
    }
}

# ---------- Mở listener ----------

$mutexCreated = $false
$mutex = New-Object Threading.Mutex($true, 'Local\ResourceGuardWatcher', [ref]$mutexCreated)
if (-not $mutexCreated) { throw 'Một watcher khác (rg-watcher.ps1 / Scheduled Task) đang chạy. Gỡ nó trước: Install-Watcher.ps1 -Uninstall, hoặc dùng trang status.html của nó.' }

$listener = $null
for ($p = $Port; $p -lt $Port + 20; $p++) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/"); $l.Prefixes.Add("http://127.0.0.1:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { try { $l.Close() } catch { } }
}
if (-not $listener) { $mutex.ReleaseMutex(); throw "Không mở được cổng nào trong $Port-$($Port + 19)." }

$url = "http://localhost:$Port/"
Set-Content -LiteralPath $script:InfoPath -Value (ConvertTo-Json ([ordered]@{ pid = $PID; port = $Port; url = $url; startedUtc = (Get-Date).ToUniversalTime().ToString('o') }) -Compress) -Encoding UTF8
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
Write-RgLog 'server-start' ([ordered]@{ pid = $PID; url = $url; mode = (Get-RgPolicy).mode })

Write-Host ''
Write-Host "  Resource Guard đang chạy (tự dọn: $((Get-RgPolicy).mode))" -ForegroundColor Green
Write-Host "  UI realtime : $url" -ForegroundColor Cyan
Write-Host "  Cài đặt     : ${url}#settings    (chu kỳ lấy mẫu hiện tại: $((Get-RgSettings).intervalSec)s)"
Write-Host "  Dừng        : nút ""Thoát Resource Guard"" trên giao diện, hoặc Ctrl+C trong terminal này (đóng cửa sổ này cũng dừng app)"
Write-Host ''
if (-not $argNoOpen) { try { Start-Process $url } catch { } }

# ---------- Vòng chính: nhận request + lấy mẫu theo chu kỳ ----------

$sse = New-Object System.Collections.ArrayList
$script:AutoSpawnedAt = [datetime]::MinValue
$script:StopRequested = $false
$live = $null
$nextSample = [datetime]::MinValue
$nextBeat = (Get-Date).AddSeconds(10)
$accept = $listener.GetContextAsync()
try {
    while ($listener.IsListening -and -not $script:StopRequested) {
        $got = $false
        try { $got = $accept.Wait(200) } catch { $accept = $listener.GetContextAsync(); Start-Sleep -Milliseconds 200 }
        if ($got) {
            $ctx = $accept.Result
            $accept = $listener.GetContextAsync()
            try {
                $req = $ctx.Request
                $path = $req.Url.AbsolutePath
                if (-not (Test-RgRequestAllowed $ctx $Port)) { Send-Bytes $ctx 403 'text/plain' ([Text.Encoding]::UTF8.GetBytes('forbidden')) }
                elseif ($path -eq '/' -or $path -eq '/index.html') {
                    $f = Join-Path $script:UiDir 'index.html'
                    Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($f))
                }
                elseif ($path -eq '/api/shutdown' -and $req.HttpMethod -eq 'POST') {
                    $busyNames = @()
                    if (Test-RgJobRunning 'cleanup.progress.json') { $busyNames += 'dọn dẹp/khôi phục' }
                    if (Test-RgJobRunning 'auto.progress.json') { $busyNames += 'tự dọn' }
                    if ($busyNames.Count) {
                        Send-Json $ctx ([ordered]@{ ok = $false; busy = $true; error = 'Đang có lượt ' + ($busyNames -join ' và ') + ' chưa xong; thoát lúc này có thể bỏ dở thao tác xoá.' }) 409
                    } else {
                        Stop-RgReadOnlyJobs
                        Send-Json $ctx ([ordered]@{ ok = $true })
                        $script:StopRequested = $true
                    }
                }
                elseif ($path -eq '/api/state') { Send-Json $ctx $live }
                elseif ($path -eq '/api/history') { Send-Json $ctx @(Read-RgMetricsTail 480) }
                elseif ($path -eq '/api/events') { Send-Json $ctx @(Get-RgRecentEvents 30) }
                elseif ($path -eq '/api/settings' -and $req.HttpMethod -eq 'GET') {
                    Send-Json $ctx ([ordered]@{ intervalSec = (Get-RgSettings).intervalSec; minSec = $script:MinIntervalSec; maxSec = $script:MaxIntervalSec; defaultSec = $script:DefaultIntervalSec; thresholds = (Get-RgThresholds); mode = (Get-RgPolicy).mode })
                }
                elseif ($path -eq '/api/settings' -and $req.HttpMethod -eq 'POST') {
                    $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                    try {
                        $v = [int](ConvertFrom-Json $body).intervalSec
                        $s = Set-RgSettings $v
                        $nextSample = (Get-Date).AddSeconds($s.intervalSec)
                        Send-Json $ctx ([ordered]@{ ok = $true; intervalSec = $s.intervalSec })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -match '^/static/([a-z0-9._-]+\.(css|js|svg))$' -and $req.HttpMethod -eq 'GET') {
                    $f = Join-Path $script:UiDir $Matches[1]
                    if (Test-Path -LiteralPath $f) { Send-Bytes $ctx 200 $script:StaticTypes[[IO.Path]::GetExtension($f)] ([IO.File]::ReadAllBytes($f)) }
                    else { Send-Bytes $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
                }
                elseif ($path -eq '/api/processes') {
                    $pol = Get-RgPolicy
                    $rows = @($script:RgLastProcs | ForEach-Object {
                            [ordered]@{ pid = $_.pid; name = $_.name; cpu = $_.cpu; ramMB = $_.ramMB; group = $_.group; agent = $_.agent; protected = (Test-RgProcessProtected ([string]$_.name) $pol) }
                        })
                    Send-Json $ctx ([ordered]@{ ts = $(if ($live) { $live.ts } else { $null }); logical = (Get-RgCpuInfo).logical; procs = $rows })
                }
                elseif ($path -eq '/api/jobs') {
                    Send-Json $ctx ([ordered]@{
                            breakdown = (Get-RgJobState 'scan-breakdown.progress.json'); candidates = (Get-RgJobState 'scan-candidates.progress.json')
                            cleanup = (Get-RgJobState 'cleanup.progress.json'); auto = (Get-RgJobState 'auto.progress.json'); agent = (Get-RgJobState 'agent.progress.json')
                        })
                }
                elseif ($path -eq '/api/drives') {
                    $cfg = Get-RgConfig; $pol = Get-RgPolicy
                    $dl = @(Get-RgDrives)
                    $rows = @($dl | ForEach-Object {
                            $dp = Get-RgDrivePolicy $pol $_.drive
                            $sf = Join-Path (Initialize-RgHome) ("state\scan-breakdown-{0}.json" -f $_.drive)
                            [ordered]@{ drive = $_.drive; label = $_.label; isSystem = $_.isSystem; totalBytes = $_.totalBytes; freeBytes = $_.freeBytes; freeGB = $_.freeGB; totalGB = $_.totalGB; state = $_.state
                                diskTrigger = $dp.diskTrigger; targetFreeGB = $dp.targetFreeGB; overridden = $dp.overridden
                                thresholds = (Get-RgDiskThresholds $cfg $_.drive)
                                scannedUtc = $(if (Test-Path -LiteralPath $sf) { (Get-Item -LiteralPath $sf).LastWriteTimeUtc.ToString('o') } else { $null }) }
                        })
                    $prim = Get-RgPrimaryDrive $dl $cfg
                    Send-Json $ctx ([ordered]@{ drives = $rows; primary = $(if ($prim) { $prim.drive } else { $null }); workspaceRoots = @(Get-RgWorkspaceRoots $cfg.cleanup) })
                }
                elseif ($path -eq '/api/disk') {
                    $q = [string]$req.QueryString['drive']
                    $dl = @(Get-RgDrives)
                    if (-not $q) { $pd = Get-RgPrimaryDrive $dl (Get-RgConfig); $q = $(if ($pd) { $pd.drive } else { 'C' }) }
                    $q = $q.ToUpperInvariant()
                    if ($q -notmatch '^[A-Z]$') { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Tên ổ không hợp lệ.' }) 400 }
                    else {
                        $b = Read-RgStateText ("scan-breakdown-{0}.json" -f $q)
                        if (-not $b) { $b = 'null' }
                        Send-RawJson $ctx ('{"drive":"' + $q + '","breakdown":' + $b + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'scan-breakdown.progress.json') -Compress -Depth 3) + '}')
                    }
                }
                elseif ($path -eq '/api/disk/scan' -and $req.HttpMethod -eq 'POST') {
                    $b = $null; try { $b = Read-RgBody $req } catch { }
                    $want = ''; if ($b -and $b.drive) { $want = ([string]$b.drive).Trim().TrimEnd(':').ToUpperInvariant() }
                    $dl = @(Get-RgDrives)
                    if (-not $want) { $pd = Get-RgPrimaryDrive $dl (Get-RgConfig); if ($pd) { $want = $pd.drive } }
                    if ($want -notmatch '^[A-Z]$' -or -not (@($dl | Where-Object { $_.drive -eq $want }))) { Send-Json $ctx ([ordered]@{ ok = $false; error = "Ổ '$want' không có hoặc không được giám sát." }) 400 }
                    elseif (Test-RgJobRunning 'scan-breakdown.progress.json') { $cur = Get-RgJobState 'scan-breakdown.progress.json'; Send-Json $ctx ([ordered]@{ ok = $true; already = $true; drive = [string]$cur.drive }) }
                    else { Start-RgJob 'rg-scan.ps1' @('-Mode', 'breakdown', '-Drive', $want); Send-Json $ctx ([ordered]@{ ok = $true; drive = $want }) }
                }
                elseif ($path -eq '/api/candidates' -and $req.HttpMethod -eq 'GET') {
                    $pol = Get-RgPolicy
                    $t = Read-RgStateText 'scan-candidates.json'
                    $cd = $null; if ($t) { try { $cd = ConvertFrom-Json $t } catch { } }
                    $items = @()
                    if ($cd) {
                        $items = @($cd.items | ForEach-Object {
                                $prot = if ($_.kind -eq 'process') { Test-RgProcessProtected ([string]$_.name) $pol } else { Test-RgPathProtected ([string]$_.path) $pol }
                                [ordered]@{ key = $_.key; kind = $_.kind; action = $_.action; level = $_.level; path = $_.path; drive = (Get-RgPathDrive ([string]$_.path)); pid = $_.pid; name = $_.name; sizeBytes = $_.sizeBytes
                                    ageDays = $_.ageDays; newestWriteUtc = $_.newestWriteUtc; reason = $_.reason; risk = $_.risk; protected = [bool]$prot; needsAdmin = [bool]$_.needsAdmin; canArchive = (Test-RgArchivable ([string]$_.kind)) -and ($_.action -eq 'delete')
                                    setting = $(if ($pol.categories.Contains([string]$_.kind)) { $pol.categories[[string]$_.kind] } else { 'keep' }) }
                            })
                    }
                    Send-Json $ctx ([ordered]@{ finishedUtc = $(if ($cd) { $cd.finishedUtc } else { $null }); seconds = $(if ($cd) { $cd.seconds } else { $null }); items = $items; progress = (Get-RgJobState 'scan-candidates.progress.json') })
                }
                elseif ($path -eq '/api/candidates/scan' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'scan-candidates.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-scan.ps1' @('-Mode', 'candidates'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/cleanup/apply' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        $keys = @($b.keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
                        if ($keys.Count -eq 0) { throw 'Chưa chọn mục nào.' }
                        if ($keys.Count -gt 200) { throw 'Chọn quá nhiều mục (tối đa 200).' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        $cArgs = @('-Keys', ($keys -join ','), '-By', 'ui')
                        if ([bool]$b.archive) { $cArgs += '-Archive' }   # chỉ có tác dụng với nhóm nén được (repo cũ, mục lớn)
                        Start-RgJob 'rg-cleanup.ps1' $cArgs
                        Send-Json $ctx ([ordered]@{ ok = $true; count = $keys.Count })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/cleanup/elevate' -and $req.HttpMethod -eq 'POST') {
                    # Chỉ nhận key của mục được quét gắn needsAdmin; việc xoá thật chạy ở tiến trình riêng SAU khi người dùng bấm "Có" ở hộp UAC của Windows.
                    try {
                        $b = Read-RgBody $req
                        $keys = @($b.keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[0-9a-f]{12}$' } | Select-Object -Unique)
                        if ($keys.Count -eq 0) { throw 'Chưa chọn mục nào.' }
                        if ($keys.Count -gt 50) { throw 'Chọn quá nhiều mục (tối đa 50).' }
                        $t = Read-RgStateText 'scan-candidates.json'
                        $cd = $null; if ($t) { try { $cd = ConvertFrom-Json $t } catch { } }
                        if (-not $cd) { throw 'Chưa có danh sách ứng viên; hãy quét trước.' }
                        $ok = @($cd.items | Where-Object { $keys -contains $_.key -and $_.kind -eq 'temp-entry' -and [bool]$_.needsAdmin } | ForEach-Object { [string]$_.key })
                        if ($ok.Count -ne $keys.Count) { throw 'Có mục không thuộc nhóm cần quyền admin.' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        Start-RgJob 'rg-elevate.ps1' @('-Keys', ($ok -join ','))
                        Send-Json $ctx ([ordered]@{ ok = $true; count = $ok.Count })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/archives' -and $req.HttpMethod -eq 'GET') {
                    $rows = @(Read-RgArchives | Sort-Object { [string]$_.createdUtc } -Descending | Select-Object -First 50 | ForEach-Object {
                            [ordered]@{ id = $_.id; original = $_.original; zip = $_.zip; kind = $_.kind; bytes = $_.bytes; zipBytes = $_.zipBytes; createdUtc = $_.createdUtc
                                restoredUtc = $_.restoredUtc; zipExists = (Test-Path -LiteralPath ([string]$_.zip) -PathType Leaf); originalExists = (Test-Path -LiteralPath ([string]$_.original)) } })
                    Send-Json $ctx ([ordered]@{ items = $rows })
                }
                elseif ($path -eq '/api/archive/restore' -and $req.HttpMethod -eq 'POST') {
                    try {
                        $b = Read-RgBody $req
                        $id = [string]$b.id
                        if ($id -notmatch '^[0-9a-f]{12}$') { throw 'Id không hợp lệ.' }
                        if (@(Read-RgArchives | Where-Object { $_.id -eq $id }).Count -eq 0) { throw 'Không tìm thấy bản nén này.' }
                        if (Test-RgJobRunning 'cleanup.progress.json') { throw 'Một lượt dọn khác đang chạy.' }
                        Start-RgJob 'rg-restore.ps1' @('-Id', $id)
                        Send-Json $ctx ([ordered]@{ ok = $true })
                    } catch { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 }
                }
                elseif ($path -eq '/api/cleanup/last') {
                    $t = Read-RgStateText 'cleanup-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'cleanup.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/api/policy' -and $req.HttpMethod -eq 'GET') {
                    Send-Json $ctx ([ordered]@{ policy = (Get-RgPolicy); pinConfigured = (Test-RgPinConfigured); kinds = $script:RgPolicyKinds })
                }
                elseif ($path -eq '/api/policy' -and $req.HttpMethod -eq 'POST') {
                    $replied = $false
                    try {
                        $b = Read-RgBody $req
                        $old = Get-RgPolicy
                        $new = ConvertTo-RgPolicy $b.policy
                        if (Test-RgPolicyNeedsPin $old $new) {
                            if (-not (Test-RgPinConfigured)) {
                                Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-not-set'; error = 'Chưa đặt PIN. Đặt ở terminal: resource-manager.ps1 serve setpin' }) 403; $replied = $true
                            } elseif ([string]::IsNullOrEmpty([string]$b.pin)) {
                                Send-Json $ctx ([ordered]@{ ok = $false; code = 'pin-required'; error = 'Cần PIN cho thay đổi này.' }) 403; $replied = $true
                            } else {
                                $pr = Test-RgPin ([string]$b.pin)
                                if (-not $pr.ok) {
                                    $code = if ($pr.locked) { 'pin-locked' } else { 'pin-wrong' }
                                    Send-Json $ctx ([ordered]@{ ok = $false; code = $code; retryAfterSec = $pr.retryAfterSec; error = $(if ($pr.locked) { "Sai PIN quá nhiều lần, thử lại sau $($pr.retryAfterSec) giây." } else { 'PIN không đúng.' }) }) 403; $replied = $true
                                }
                            }
                        }
                        if (-not $replied) {
                            $saved = Save-RgPolicy $new
                            Write-RgLog 'policy-change' ([ordered]@{ mode = $saved.mode; categories = $saved.categories; protectPaths = @($saved.protectPaths).Count; protectProcesses = @($saved.protectProcesses).Count })
                            Send-Json $ctx ([ordered]@{ ok = $true; policy = $saved; pinConfigured = (Test-RgPinConfigured) })
                        }
                    } catch { if (-not $replied) { Send-Json $ctx ([ordered]@{ ok = $false; error = [string]$_.Exception.Message }) 400 } }
                }
                elseif ($path -eq '/api/auto/run' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'auto.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-auto.ps1' @('-Force', '-DryRun', '-Trigger', 'manual'); Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/auto/last') {
                    $t = Read-RgStateText 'auto-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'auto.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/api/agent/payload') {
                    $pj = ConvertTo-Json -InputObject (New-RgAgentPayload) -Depth 8 -Compress
                    Send-RawJson $ctx ('{"bytes":' + [Text.Encoding]::UTF8.GetByteCount($pj) + ',"payload":' + $pj + '}')
                }
                elseif ($path -eq '/api/agent/run' -and $req.HttpMethod -eq 'POST') {
                    if (Test-RgJobRunning 'agent.progress.json') { Send-Json $ctx ([ordered]@{ ok = $true; already = $true }) }
                    else { Start-RgJob 'rg-agent.ps1'; Send-Json $ctx ([ordered]@{ ok = $true }) }
                }
                elseif ($path -eq '/api/agent/last') {
                    $t = Read-RgStateText 'agent-last.json'; if (-not $t) { $t = 'null' }
                    Send-RawJson $ctx ('{"last":' + $t + ',"progress":' + (ConvertTo-Json -InputObject (Get-RgJobState 'agent.progress.json') -Compress -Depth 3) + '}')
                }
                elseif ($path -eq '/events') {
                    $r = $ctx.Response
                    $r.StatusCode = 200; $r.ContentType = 'text/event-stream'; $r.SendChunked = $true
                    $r.Headers['Cache-Control'] = 'no-store'
                    [void]$sse.Add($r)
                    $first = "retry: 3000`n`n"
                    if ($live) { $first += "data: $(ConvertTo-Json -InputObject $live -Depth 6 -Compress)`n`n" }
                    Send-RgSse ([System.Collections.ArrayList]@($r)) $first
                }
                else { Send-Bytes $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
            } catch {
                Write-RgLog 'route-error' ([ordered]@{ path = [string]$path; error = [string]$_ })
                try { Send-Json $ctx ([ordered]@{ ok = $false; error = 'Lỗi nội bộ: ' + [string]$_.Exception.Message }) 500 } catch { try { $ctx.Response.Abort() } catch { } }
            }
        }

        $now = Get-Date
        if ($now -ge $nextSample) {
            try {
                $rec = Invoke-RgWatchTick -NoToast:$NoToast
                $iv = (Get-RgSettings).intervalSec
                $live = [pscustomobject]@{
                    ts = $rec.ts; state = $rec.state; rawState = $rec.rawState; availRamGB = $rec.availRamGB; totalRamGB = $rec.totalRamGB
                    commitPct = $rec.commitPct; cpuPct = $rec.cpuPct; diskDrive = $rec.diskDrive; diskFreeGB = $rec.diskFreeGB; drives = $rec.drives
                    heavy = $rec.heavy; ledgerOrphans = $rec.ledgerOrphans; top = $rec.top
                    reasons = @($script:RgLastReasons); intervalSec = $iv
                    cores = $rec.cores; topCpu = $rec.topCpu; procCount = $rec.procCount; uptimeSec = $rec.uptimeSec; cpuInfo = (Get-RgCpuInfo)
                }
                try { Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\live.json') (ConvertTo-Json -InputObject $live -Depth 5 -Compress) } catch { }
                try {   # tự dọn nền: chỉ spawn khi mode != off, có áp lực và hết cooldown
                    $pol = Get-RgPolicy
                    if ([string]$pol.mode -ne 'off' -and ((Get-Date) - $script:AutoSpawnedAt).TotalSeconds -ge 90) {
                        $stress = Get-RgStressInfo $pol (Get-RgConfig) $rec
                        if (Test-RgAutoDue $pol $stress) {
                            $script:AutoSpawnedAt = Get-Date
                            Write-RgLog 'auto-spawn' ([ordered]@{ mode = $pol.mode; disk = $stress.diskState; ram = $stress.ramState })
                            Start-RgJob 'rg-auto.ps1' @('-Trigger', 'state')
                        }
                    }
                } catch { Write-RgLog 'auto-check-error' ([string]$_) }
                Send-RgSse $sse "data: $(ConvertTo-Json -InputObject $live -Depth 6 -Compress)`n`n"
            } catch { Write-RgLog 'server-tick-error' ([string]$_) }
            # Tính từ lúc BẮT ĐẦU tick (không cộng thời gian tick vào chu kỳ); tối thiểu 1s để không quay vòng liên tục.
            $nextSample = $now.AddSeconds((Get-RgSettings).intervalSec)
            $floor = (Get-Date).AddSeconds(1)
            if ($nextSample -lt $floor) { $nextSample = $floor }
        }
        if ($now -ge $nextBeat) { Send-RgSse $sse ": hb`n`n"; $nextBeat = $now.AddSeconds(10) }
    }
}
finally {
    Write-RgLog 'server-stop' ([ordered]@{ pid = $PID; reason = $(if ($script:StopRequested) { 'ui-or-cli' } else { 'ctrl-c-or-error' }) })
    foreach ($c in @($sse.ToArray())) { try { $c.Close() } catch { } }
    try { $listener.Stop(); $listener.Close() } catch { }
    Remove-Item -LiteralPath $script:InfoPath -Force -ErrorAction SilentlyContinue
    try { $mutex.ReleaseMutex() } catch { }
}
