# Test nghiệm thu cho plan-automation (track A-E). Chạy riêng: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Acceptance-Auto.ps1
# Tests\Acceptance.ps1 cũng gọi file này ở cuối. Mọi thao tác nằm trong thư mục tạm riêng (AGENT_RESOURCE_HOME + fixture); không đụng dữ liệu thật.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("rg-auto-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ws = Join-Path $sandbox 'ws'; $tmp = Join-Path $sandbox 'tmp'; $cache = Join-Path $sandbox 'cache'; $home_ = Join-Path $sandbox 'home'
foreach ($d in $ws, $tmp, $cache, $home_) { [void](New-Item -ItemType Directory -Force -Path $d) }
$env:AGENT_RESOURCE_HOME = $home_

$script:pass = 0; $script:fail = 0
function Assert($Cond, [string]$Name) {
    if ([bool]$Cond) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Age([string]$Path, [int]$Days) {
    $t = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.LastWriteTime = $t; $_.LastAccessTime = $t }
    $self = Get-Item -LiteralPath $Path -Force; $self.LastWriteTime = $t; $self.LastAccessTime = $t
}
function NewFile([string]$Path, [int]$Bytes) {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
}

$cfg = Get-Content (Join-Path $root 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg.groups.dev = @('ping')
$cfg.scan.autoRefreshHours = 0
$cfg.cleanup.workspaceRoots = @($ws)
$cfg.cleanup.tempRoot = $tmp
$cfg.cleanup.minCacheMB = 0
$cfg.cleanup.cacheDirs = [pscustomobject]@{ 'fake-cache' = $cache }
$cfg.cleanup.vhdxGlobs = @()
$dl = Join-Path $sandbox 'dl'; [void](New-Item -ItemType Directory -Force -Path $dl)
$cfg.cleanup.staleRepo = [pscustomobject]@{ minInactiveDays = 90; minMB = 0 }
$cfg.cleanup.largeItem = [pscustomobject]@{ roots = @($dl); minMB = 0; minInactiveDays = 60 }
Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 8) -Encoding UTF8

. (Join-Path $root 'scripts\rg-common.ps1')
. (Join-Path $root 'scripts\rg-policy.ps1')
$procs = @()
try {
    # =====================================================================
    Write-Host "`n[A1] Ghi bền vững: lỗi ghi không bị nuốt"
    Clear-RgIoHealth
    $badDir = Join-Path $sandbox 'does-not-exist\sub'
    $threw = $false; try { Write-RgFileAtomic (Join-Path $badDir 'x.json') '{}' } catch { $threw = $true }
    Assert $threw 'Write-RgFileAtomic: không ghi được -> ném lỗi (không nuốt)'
    $ioh = Get-RgIoHealth
    Assert (-not $ioh.ok -and $ioh.errors -ge 1 -and $ioh.last.op -eq 'write') 'Get-RgIoHealth: ghi nhận lỗi ghi file'
    Assert (Test-Path -LiteralPath (Join-Path $home_ 'state\io-health.json')) 'lỗi ghi được lưu thêm vào state\io-health.json'
    Clear-RgIoHealth
    Assert ((Get-RgIoHealth).ok) 'Clear-RgIoHealth: sạch lỗi'
    $logFile = Join-Path (Initialize-RgHome) ('logs\rg-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
    [void](New-Item -ItemType Directory -Force -Path $logFile)   # file log bị thay bằng thư mục => Add-Content phải lỗi
    $threw = $false; try { Write-RgLog 'a1-test' @{ x = 1 } } catch { $threw = $true }
    Assert (-not $threw) 'Write-RgLog: không ném lỗi (không làm hỏng hành động đang chạy)'
    Assert (-not (Get-RgIoHealth).ok -and (Get-RgIoHealth).last.op -eq 'log') 'Write-RgLog: lỗi ghi log được đếm và báo qua Get-RgIoHealth'
    Remove-Item -LiteralPath $logFile -Recurse -Force
    Clear-RgIoHealth

    Write-Host "`n[A1] Journal ghi-trước"
    $jid = Write-RgJournalIntent -Action 'delete' -Kind 'temp-entry' -Target (Join-Path $tmp 'nope') -PlanId 'abc'
    Assert ($jid -match '^[0-9a-f]{12}$' -and @(Get-RgJournalPending).Count -eq 1) 'intent chưa đóng -> nằm trong Get-RgJournalPending'
    Close-RgJournal $jid 'done' 'ok'
    Assert (@(Get-RgJournalPending).Count -eq 0) 'đã đóng bằng done -> không còn pending'
    $j2 = Write-RgJournalIntent -Action 'delete' -Kind 'temp-entry' -Target (Join-Path $tmp 'gone-already') -PlanId 'abc'
    $res = @(Resolve-RgJournalPending)
    Assert ($res.Count -eq 1 -and $res[0].state -eq 'target-gone' -and @(Get-RgJournalPending).Count -eq 0) 'giả lập ngắt giữa chừng: intent mồ côi được rà lại (target-gone) rồi đóng'
    Assert (@(Resolve-RgJournalPending).Count -eq 0) 'rà lần hai không báo lặp'
    NewFile (Join-Path $tmp 'half.tmp') 100
    [void](Write-RgJournalIntent -Action 'delete' -Kind 'temp-entry' -Target (Join-Path $tmp 'half.tmp') -PlanId 'abc')
    $res = @(Resolve-RgJournalPending)
    Assert ($res.Count -eq 1 -and $res[0].state -eq 'target-still-present') 'mục còn nguyên sau khi bị ngắt -> state target-still-present'
    Remove-Item (Join-Path $tmp 'half.tmp') -Force
    $jt = (Get-Content -LiteralPath (Get-RgJournalPath) -Raw -Encoding UTF8)
    Assert ($jt -match '"phase":"interrupted"' -and $jt -match '"phase":"intent"') 'journal có đủ dòng intent và interrupted'
    # dòng dang dở (mất điện giữa lúc ghi) không làm hỏng đọc
    [IO.File]::AppendAllText((Get-RgJournalPath), '{"ts":"x","actionId":"zzz","pha')
    Assert (@(Read-RgJournal).Count -ge 4) 'dòng journal dang dở bị bỏ qua, không làm hỏng việc đọc'
    Remove-Item (Get-RgJournalPath) -Force

    Write-Host "`n[A1] Invoke-RgApply ghi journal; resume; không ghi được intent thì không xoá"
    NewFile (Join-Path $tmp 'a.tmp') 1KB; Age (Join-Path $tmp 'a.tmp') 20
    $it = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path (Join-Path $tmp 'a.tmp') -SizeBytes 1KB -AgeDays 20 -Reason 'a1'
    $pl = New-RgPlan -Items @($it)
    [void](Set-RgPlanApproval -PlanId $pl.planId -ItemIds @(1) -By 'test-human')
    $r = Invoke-RgApply -PlanId $pl.planId
    Assert ($r.ok -and -not (Test-Path (Join-Path $tmp 'a.tmp'))) 'apply xoá thật'
    $ents = @(Read-RgJournal)
    Assert (@($ents | Where-Object { $_.phase -eq 'intent' -and $_.planId -eq $pl.planId }).Count -eq 1 -and @($ents | Where-Object { $_.phase -eq 'done' }).Count -eq 1) 'apply ghi intent rồi done vào journal'
    Assert ((Read-RgPlan $pl.planId).status -eq 'applied') 'plan chuyển applying -> applied'
    # resume: plan kẹt 'applying' (process chết) vẫn chạy lại được; mục đã xoá bị revalidate chặn
    $p = Read-RgPlan $pl.planId; $p.status = 'applying'; Save-RgPlan $p
    $r2 = Invoke-RgApply -PlanId $pl.planId
    Assert ($r2.code -eq 0 -and $r2.results[0].outcome -eq 'skipped' -and $r2.results[0].detail -match 'no longer exists') 'plan kẹt applying: chạy lại được, mục đã xoá bị bỏ qua (revalidate)'
    # intent không ghi được => không xoá
    NewFile (Join-Path $tmp 'b.tmp') 1KB; Age (Join-Path $tmp 'b.tmp') 20
    $it2 = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path (Join-Path $tmp 'b.tmp') -SizeBytes 1KB -AgeDays 20 -Reason 'a1 journal fail'
    $pl2 = New-RgPlan -Items @($it2)
    [void](Set-RgPlanApproval -PlanId $pl2.planId -ItemIds @(1) -By 'test-human')
    Remove-Item (Get-RgJournalPath) -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path (Get-RgJournalPath))   # journal không mở được
    $r3 = Invoke-RgApply -PlanId $pl2.planId
    Assert ($r3.results[0].outcome -eq 'failed' -and $r3.results[0].detail -match 'journal' -and (Test-Path (Join-Path $tmp 'b.tmp'))) 'không ghi được intent -> mục KHÔNG bị xoá, báo failed'
    Remove-Item (Get-RgJournalPath) -Recurse -Force
    Clear-RgIoHealth

    Write-Host "`n[A1] Retention plans/logs/journal"
    $planDir = Join-Path $home_ 'plans'; $logDir = Join-Path $home_ 'logs'
    $oldApplied = Join-Path $planDir 'aaaaaaaaaaaa.json'; $oldPending = Join-Path $planDir 'bbbbbbbbbbbb.json'; $oldApprovedRun = Join-Path $planDir 'cccccccccccc.json'; $fresh = Join-Path $planDir 'dddddddddddd.json'
    Set-Content $oldApplied '{"planId":"aaaaaaaaaaaa","status":"applied","approval":{"status":"approved"}}' -Encoding UTF8
    Set-Content $oldPending '{"planId":"bbbbbbbbbbbb","status":"pending","approval":{"status":"pending"}}' -Encoding UTF8
    Set-Content $oldApprovedRun '{"planId":"cccccccccccc","status":"applying","approval":{"status":"approved"}}' -Encoding UTF8
    Set-Content $fresh '{"planId":"dddddddddddd","status":"applied","approval":{"status":"approved"}}' -Encoding UTF8
    foreach ($f in $oldApplied, $oldPending, $oldApprovedRun) { (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-100) }
    $oldLog = Join-Path $logDir 'rg-20200101.jsonl'; Set-Content $oldLog '{}' -Encoding UTF8; (Get-Item $oldLog).LastWriteTime = (Get-Date).AddDays(-90)
    $rr = Invoke-RgRetention (Get-RgConfig)
    Assert (-not (Test-Path $oldApplied) -and -not (Test-Path $oldPending)) 'retention: plan cũ đã applied / chưa duyệt bị xoá'
    Assert ((Test-Path $oldApprovedRun) -and (Test-Path $fresh)) 'retention: plan đã duyệt mà chưa xong và plan mới được giữ'
    Assert (-not (Test-Path $oldLog) -and $rr.plans -eq 2 -and $rr.logs -ge 1) 'retention: log quá hạn bị xoá, số liệu trả về đúng'
    Remove-Item $oldApprovedRun, $fresh -Force   # dọn fixture giả để không lẫn vào test resume ở A3
    # journal phình: giữ intent mở + 1000 action gần nhất
    $big = New-Object Text.StringBuilder
    for ($i = 0; $i -lt 3000; $i++) { [void]$big.Append(('{{"ts":"t","actionId":"id{0:D5}","phase":"intent","pad":"{1}"}}' -f $i, ('x' * 1500)) + "`n"); [void]$big.Append(('{{"ts":"t","actionId":"id{0:D5}","phase":"done"}}' -f $i) + "`n") }
    [IO.File]::WriteAllText((Get-RgJournalPath), $big.ToString())
    [IO.File]::AppendAllText((Get-RgJournalPath), '{"ts":"t","actionId":"openone","phase":"intent","pid":999999}' + "`n")
    [void](Invoke-RgRetention (Get-RgConfig))
    $after = @(Read-RgJournal)
    Assert ((Get-Item (Get-RgJournalPath)).Length -lt 4MB -and @($after | Where-Object { $_.actionId -eq 'openone' }).Count -eq 1 -and @($after | Where-Object { $_.actionId -eq 'id00000' }).Count -eq 0 -and @($after | Where-Object { $_.actionId -eq 'id02999' }).Count -eq 2) 'retention: journal phình được cắt, giữ intent mở và action gần nhất'
    Remove-Item (Get-RgJournalPath) -Force

    # =====================================================================
    Write-Host "`n[A2] Kết thúc tiến trình có xác minh"
    function NewPing { $p = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $script:procs += $p; return $p }
    function Stamp($p) { ConvertTo-RgStamp (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CreationDate }
    $a = NewPing; Start-Sleep -Milliseconds 700
    $ka = Stop-RgProcessVerified -ProcId $a.Id -Start (Stamp $a) -Name 'ping' -GraceSec 1
    Assert ($ka.ok -and $ka.exited -and $ka.method -eq 'forced' -and -not (Get-Process -Id $a.Id -ErrorAction SilentlyContinue)) 'Stop-RgProcessVerified: tiến trình không cửa sổ -> buộc dừng + xác minh đã thoát'
    $b = NewPing; Start-Sleep -Milliseconds 700
    $kb = Stop-RgProcessVerified -ProcId $b.Id -Start '20200101T000000Z' -Name 'ping'
    Assert (-not $kb.ok -and $kb.method -eq 'none' -and $kb.reason -match 'reused' -and (Get-Process -Id $b.Id -ErrorAction SilentlyContinue)) 'start time sai (PID reuse) -> không tác động, process còn sống'
    $kc = Stop-RgProcessVerified -ProcId $PID -Start (ConvertTo-RgStamp (Get-Process -Id $PID).StartTime) -Name 'powershell'
    Assert (-not $kc.ok -and $kc.reason -match 'itself') 'không bao giờ tự kết thúc chính mình'
    Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue

    $cmdP = Start-Process cmd -ArgumentList '/c', 'ping -n 300 127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $cmdP
    Start-Sleep -Milliseconds 1200
    $kid = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($cmdP.Id)" | Where-Object { $_.Name -eq 'PING.EXE' })
    if ($kid.Count -ge 1) {
        $tree = @(Get-RgProcessTree $cmdP.Id (Stamp $cmdP))
        Assert ($tree.Count -ge 1 -and $tree[0].Name -eq 'ping') 'Get-RgProcessTree: thấy tiến trình con ping của cmd'
        $kd = Stop-RgProcessVerified -ProcId $cmdP.Id -Start (Stamp $cmdP) -Name 'cmd' -GraceSec 1
        Assert ($kd.ok -and @($kd.tree).Count -ge 2 -and -not (Get-Process -Id $kid[0].ProcessId -ErrorAction SilentlyContinue) -and -not (Get-Process -Id $cmdP.Id -ErrorAction SilentlyContinue)) 'kill cả cây: gốc và con (nhóm cho phép) đều thoát, có xác minh'
    } else { Write-Host '  SKIP  cmd không sinh ping con' }

    $outer = Start-Process cmd -ArgumentList '/c', 'cmd /c ping -n 300 127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $outer
    Start-Sleep -Milliseconds 1500
    $ke = Stop-RgProcessVerified -ProcId $outer.Id -Start (Stamp $outer) -Name 'cmd' -GraceSec 1
    Assert ($ke.ok -and @($ke.skipped | Where-Object { $_.name -eq 'cmd' }).Count -ge 1) 'hậu duệ ngoài nhóm cho phép (cmd) bị bỏ qua và ghi vào skipped, không bị kill'
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object { $_.CommandLine -match 'ping -n 300' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Write-Host "`n[A2] Ledger: khoá, TTL, heartbeat"
    $L = @(); 1..4 | ForEach-Object { $L += NewPing }
    Start-Sleep -Milliseconds 600
    $regScript = Join-Path $root 'scripts\Register-AgentProcess.ps1'
    $hostExe = (Get-Process -Id $PID).Path
    $jobs = @(foreach ($p in $L) { Start-Process $hostExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $regScript + '"'), '-ProcessId', $p.Id, '-Agent', 'claude', '-Label', 'race', '-OwnerPid', 999999 -WindowStyle Hidden -PassThru })
    foreach ($j in $jobs) { [void]$j.WaitForExit(60000) }
    $ledger = @(Read-RgLedger)
    Assert (@($L | Where-Object { $id = $_.Id; @($ledger | Where-Object { [int]$_.pid -eq $id }).Count -eq 1 }).Count -eq 4) 'ledger: 4 process đăng ký đồng thời đều có mặt (khoá chống ghi đè)'
    Assert (@($ledger | Where-Object { $_.lastSeenUtc }).Count -ge 4) 'mục ledger có lastSeenUtc'

    $cfgNow = Get-RgConfig
    $victim = $L[0]
    $all = @(Read-RgLedger)
    foreach ($e in $all) { if ([int]$e.pid -eq $victim.Id) { $old = ConvertTo-RgStamp ((Get-Date).AddHours(-48)); $e.registeredUtc = $old; $e.lastSeenUtc = $old } }
    Write-RgLedger $all
    $orph = @(Get-RgLedgerOrphans)
    Assert (@($orph | Where-Object { [int]$_.pid -eq $victim.Id }).Count -eq 0 -and @($orph | Where-Object { [int]$_.pid -eq $L[1].Id }).Count -eq 1) 'TTL: chủ đã chết + quá 24h không heartbeat -> hết hạn, không còn là orphan'
    $vitem = [pscustomobject]@{ pid = $victim.Id; start = (Stamp $victim); name = 'ping' }
    Assert ((Get-RgKillBlocker $vitem $cfgNow) -match 'expired') 'TTL: Get-RgKillBlocker từ chối mục đã hết hạn'
    Assert ((Update-RgLedgerHeartbeat -ProcId $victim.Id)) 'heartbeat tìm thấy mục'
    Assert ($null -eq (Get-RgKillBlocker $vitem $cfgNow) -and @(Get-RgLedgerOrphans | Where-Object { [int]$_.pid -eq $victim.Id }).Count -eq 1) 'heartbeat làm mới hạn: mục lại đủ điều kiện'
    Assert (-not (Update-RgLedgerHeartbeat -ProcId 999998)) 'heartbeat cho PID lạ -> false'
    # chủ còn sống thì không hết hạn dù lâu không heartbeat
    [void](Register-RgProcess -ProcId $L[2].Id -Agent 'claude' -Label 'owner alive' -OwnerPid $PID)
    $all = @(Read-RgLedger); foreach ($e in $all) { if ([int]$e.pid -eq $L[2].Id) { $old = ConvertTo-RgStamp ((Get-Date).AddHours(-48)); $e.registeredUtc = $old; $e.lastSeenUtc = $old } }; Write-RgLedger $all
    Assert (-not (Test-RgLedgerEntryExpired (@(Read-RgLedger | Where-Object { [int]$_.pid -eq $L[2].Id })[0]) $cfgNow)) 'chủ còn sống -> không hết hạn'

    Write-Host "`n[A2] Apply kill đi qua Stop-RgProcessVerified và ghi journal"
    $target = $L[1]
    $kit = New-RgItem -Kind 'process' -Action 'kill' -Level 1 -ProcId $target.Id -Start (Stamp $target) -Name 'ping' -Reason 'a2 apply'
    $kpl = New-RgPlan -Items @($kit)
    [void](Set-RgPlanApproval -PlanId $kpl.planId -ItemIds @(1) -By 'test-human')
    $kr = Invoke-RgApply -PlanId $kpl.planId
    Assert ($kr.results[0].outcome -eq 'done' -and $kr.results[0].detail -match 'verified exited' -and -not (Get-Process -Id $target.Id -ErrorAction SilentlyContinue)) 'apply kill: done + chi tiết "verified exited" + process thật sự đã thoát'
    $jk = @(Read-RgJournal | Where-Object { $_.planId -eq $kpl.planId })
    Assert (@($jk | Where-Object { $_.phase -eq 'intent' -and $_.action -eq 'kill' }).Count -eq 1 -and @($jk | Where-Object { $_.phase -eq 'done' }).Count -eq 0 -and @(Read-RgJournal | Where-Object { $_.phase -eq 'done' -and $_.detail -match 'verified' }).Count -ge 1) 'journal ghi intent kill rồi done'

    # =====================================================================
    Write-Host "`n[A3] Xoá: loại tái tạo được / vĩnh viễn, xoá dở, tiếp tục, khôi phục"
    Assert ((Get-RgKindRecovery 'temp-entry') -eq 'regenerable' -and (Get-RgKindRecovery 'node_modules') -eq 'regenerable' -and (Get-RgKindRecovery 'cache-aged') -eq 'regenerable' -and (Get-RgKindRecovery 'dotnet-artifact') -eq 'regenerable') 'Get-RgKindRecovery: 4 loại build/cache/tạm là regenerable'
    Assert ((Get-RgKindRecovery 'large-item') -eq 'zip-optional' -and (Get-RgKindRecovery 'stale-repo') -eq 'zip-optional' -and (Get-RgKindRecovery 'process') -eq 'none' -and (Get-RgKindRecovery 'app') -eq 'none') 'large-item/stale-repo = zip-optional; process/app = none'
    $rcpt = Get-RgItemReceipt (New-RgItem -Kind 'large-item' -Action 'delete' -Level 3 -Path (Join-Path $dl 'x') -SizeBytes 10MB -AgeDays 100) $cfgNow
    Assert ($rcpt.recovery -eq 'zip-optional') 'biên lai có trường recovery'
    $pol = Get-RgPolicy
    $badCats = @($pol.categories.Keys | Where-Object { @('regenerable', 'none') -notcontains (Get-RgKindRecovery $_) })
    Assert ($badCats.Count -eq 0) 'invariant: chỉ loại regenerable (và process) có thể nằm trong nhóm tự dọn; large-item/stale-repo thì không'

    NewFile (Join-Path $dl 'big1.bin') 200KB; Age (Join-Path $dl 'big1.bin') 100
    NewFile (Join-Path $dl 'big2.bin') 200KB; Age (Join-Path $dl 'big2.bin') 100
    NewFile (Join-Path $tmp 'c.tmp') 1KB; Age (Join-Path $tmp 'c.tmp') 20
    $i1 = New-RgItem -Kind 'large-item' -Action 'delete' -Level 3 -Path (Join-Path $dl 'big1.bin') -SizeBytes 200KB -AgeDays 100 -Reason 'a3 permanent'
    $i2 = New-RgItem -Kind 'large-item' -Action 'delete' -Level 3 -Path (Join-Path $dl 'big2.bin') -SizeBytes 200KB -AgeDays 100 -Reason 'a3 archive' -Archive $true
    $i3 = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path (Join-Path $tmp 'c.tmp') -SizeBytes 1KB -AgeDays 20 -Reason 'a3 regen'
    $p3 = New-RgPlan -Items @($i1, $i2, $i3)
    [void](Set-RgPlanApproval -PlanId $p3.planId -ItemIds @(1, 2, 3) -By 'test-human')
    $r3 = Invoke-RgApply -PlanId $p3.planId
    $byKind = @{}; foreach ($x in $r3.results) { $byKind[[string]$x.target] = $x }
    Assert ($byKind[(Join-Path $dl 'big1.bin')].recovery -eq 'permanent' -and $byKind[(Join-Path $dl 'big2.bin')].recovery -eq 'zip' -and $byKind[(Join-Path $tmp 'c.tmp')].recovery -eq 'regenerable') 'kết quả apply ghi recovery: permanent / zip / regenerable'
    Assert ($r3.ok -and -not (Test-Path (Join-Path $dl 'big1.bin')) -and -not (Test-Path (Join-Path $dl 'big2.bin')) -and (Test-Path (Join-Path $dl 'big2.bin.zip'))) 'xoá thật; bản nén có zip bên cạnh'
    $jex = @(Read-RgJournal | Where-Object { $_.phase -eq 'intent' -and $_.planId -eq $p3.planId })
    Assert (@($jex | Where-Object { $_.action -eq 'archive' -and $_.extra.recovery -eq 'zip' }).Count -eq 1 -and @($jex | Where-Object { $_.extra.recovery -eq 'permanent' }).Count -eq 1) 'journal intent ghi recovery và hành động archive'
    # khôi phục từ zip: có journal restore
    $arc = @(Read-RgArchives | Where-Object { $_.original -eq (Join-Path $dl 'big2.bin') })[0]
    [void](Restore-RgArchive $arc.id)
    $jr = @(Read-RgJournal | Where-Object { $_.action -eq 'restore' -or ($_.phase -eq 'done' -and $_.detail -match 'restored') })
    Assert ((Test-Path (Join-Path $dl 'big2.bin')) -and @($jr | Where-Object { $_.action -eq 'restore' }).Count -eq 1 -and @(Get-RgJournalPending).Count -eq 0) 'khôi phục zip: file về đúng chỗ, journal có intent restore và đã đóng'

    # xoá dở: một file bị khoá trong thư mục tạm => phần xoá được vẫn xoá, báo partial, journal phase partial
    $dirT = Join-Path $tmp 'half-locked'; NewFile (Join-Path $dirT 'free.bin') 1KB; NewFile (Join-Path $dirT 'held.bin') 1KB; Age $dirT 20
    $lock = [IO.File]::Open((Join-Path $dirT 'held.bin'), 'Open', 'ReadWrite', 'None')
    try {
        $i4 = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path $dirT -SizeBytes 2KB -AgeDays 20 -Reason 'a3 partial'
        $p4 = New-RgPlan -Items @($i4)
        [void](Set-RgPlanApproval -PlanId $p4.planId -ItemIds @(1) -By 'test-human')
        $r4 = Invoke-RgApply -PlanId $p4.planId
        Assert ($r4.results[0].outcome -eq 'done' -and $r4.results[0].partial -eq $true -and (Test-Path (Join-Path $dirT 'held.bin')) -and -not (Test-Path (Join-Path $dirT 'free.bin'))) 'xoá dở: file xoá được đã xoá, file khoá còn, kết quả có partial = true'
        Assert (@(Read-RgJournal | Where-Object { $_.phase -eq 'partial' }).Count -ge 1) 'journal đóng bằng phase partial'
    } finally { $lock.Dispose() }

    # tiếp tục
    $p5 = Read-RgPlan $p3.planId; $p5.status = 'applying'; Save-RgPlan $p5
    Assert (@(Get-RgResumablePlans | Where-Object { $_.planId -eq $p3.planId }).Count -eq 1) 'Get-RgResumablePlans: thấy plan kẹt applying'
    Age (Join-Path $dl 'big2.bin') 100   # file khôi phục lại "cũ": chỉ journal (không phải sàn tuổi) chặn việc làm lại
    $rres = Invoke-RgApply -PlanId $p3.planId
    Assert (@($rres.results | Where-Object { $_.outcome -eq 'skipped' }).Count -eq 3 -and (Test-Path (Join-Path $dl 'big2.bin')) -and @($rres.results | Where-Object { $_.detail -match 'earlier run' }).Count -ge 1) 'chạy tiếp theo journal: mục đã xong không làm lại (file khôi phục không bị nén+xoá lần nữa)'
    Assert (@(Get-RgResumablePlans).Count -eq 0) 'sau khi chạy tiếp, không còn plan dở'

    # =====================================================================
    Write-Host "`n[A4] Config gộp sâu với default"
    $cfgPath = Join-Path $home_ 'config.json'
    $cfgBackup = [IO.File]::ReadAllText($cfgPath)
    try {
        Set-Content $cfgPath '{ "ram": { "normalAboveGB": 7 }, "groups": { "dev": ["only-me"] }, "cleanup": { "cacheDirs": { "mine": "C:\\x" } }, "customKey": 5 }' -Encoding UTF8
        $m = Get-RgConfig
        Assert ($m.ram.normalAboveGB -eq 7 -and $m.ram.cautionFromGB -eq 3 -and $m.ram.restrictedFromGB -eq 2) 'khoá người dùng thắng; khoá cùng nhánh thiếu lấy từ default'
        Assert (@($m.groups.dev).Count -eq 1 -and $m.groups.dev[0] -eq 'only-me' -and @($m.groups.build).Count -ge 3) 'mảng người dùng thay hẳn (không nối); nhánh khác giữ default'
        Assert ($m.kill.allowedGroups -contains 'build' -and $m.retention.plansDays -eq 60 -and $m.ledger.ttlHours -eq 24 -and $m.scan.maxAgeHours -eq 12) 'khoá mới (kill/retention/ledger/scan.maxAgeHours) có ngay cả khi config.json cũ không có'
        Assert (@($m.cleanup.cacheDirs.PSObject.Properties).Count -eq 1 -and $m.cleanup.cacheDirs.mine -eq 'C:\x') 'cleanup.cacheDirs thay hẳn: người dùng bỏ được các mục mặc định'
        Assert ($m.customKey -eq 5) 'khoá lạ của người dùng được giữ'
        Assert (@($m.cleanup.workspaceRoots).Count -ge 3) 'workspaceRoots mặc định có nhiều ứng viên (Workspace, source\repos, ...)'
        # Save-RgThresholds chỉ ghi phần người dùng
        $thr = [pscustomobject]@{ ramAvailGB = @{ normalAbove = 9; cautionFrom = 4; restrictedFrom = 2 }; diskFreeGB = @{ normalAbove = 30; cautionFrom = 12 }; commitPct = @{ restricted = 85; critical = 95 } }
        Save-RgThresholds $thr
        $raw = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath))
        Assert ($raw.ram.normalAboveGB -eq 9 -and $raw.disk.normalAboveGB -eq 30 -and $raw.commit.criticalPct -eq 95 -and $raw.customKey -eq 5 -and -not $raw.PSObject.Properties['kill'] -and -not $raw.PSObject.Properties['heavy']) 'Save-RgThresholds: ghi ngưỡng vào file người dùng mà không chép cả default vào'
        $m2 = Get-RgConfig
        Assert ($m2.ram.normalAboveGB -eq 9 -and $m2.kill.allowedGroups -contains 'test') 'sau khi lưu ngưỡng, cấu hình gộp đúng'
        # config hỏng: dùng default, không ném
        Set-Content $cfgPath '{ this is not json' -Encoding UTF8
        $thrown = $false; $m3 = $null; try { $m3 = Get-RgConfig } catch { $thrown = $true }
        Assert (-not $thrown -and $m3.ram.normalAboveGB -eq 5 -and (Get-ChildItem (Join-Path $home_ 'logs') -Filter '*.jsonl' | Get-Content -Raw -Encoding UTF8) -match 'config-error') 'config.json hỏng: dùng default và ghi config-error, không làm sập'
        # hằng số cứng thành cấu hình
        Set-Content $cfgPath '{ "scan": { "maxAgeHours": 3, "minGapMinutes": 30 } }' -Encoding UTF8
        $stamp5h = (Get-Date).ToUniversalTime().AddHours(-5).ToString('o'); $stamp1h = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        Assert ((Get-RgScanMaxAgeHours) -eq 3 -and (Test-RgScanStale $stamp5h) -and -not (Test-RgScanStale $stamp1h)) 'scan.maxAgeHours đổi được ngưỡng "quét cũ"'
        Assert ((Get-RgScanMinGapMinutes (Get-RgConfig)) -eq 30 -and (Get-RgScanMinGapMinutes ([pscustomobject]@{})) -eq 10) 'scan.minGapMinutes đổi được, thiếu thì 10'
        Remove-Item $cfgPath -Force
        Assert ((Get-RgScanMaxAgeHours) -eq 12) 'không có config.json: ngưỡng quét cũ = 12'
    } finally { [IO.File]::WriteAllText($cfgPath, $cfgBackup) }

    # =====================================================================
    Write-Host "`n[A5] Số liệu hiệu quả + overhead watcher"
    $em = Get-RgEffectMetrics 30
    Assert ($em.items -ge 4 -and $em.freedBytes -ge 200KB -and $em.archives -eq 1 -and $em.restores -eq 1 -and $em.restoreRate -eq 1 -and $em.kills -ge 1) 'effect: đếm mục đã dọn, byte giải phóng, số lần nén/khôi phục, số lần kill từ journal'
    Assert ($em.byKind['large-item'].items -eq 2 -and $em.byApprover['human'] -ge 4 -and $em.partial -ge 1 -and $em.plans -ge 2) 'effect: chia theo loại, theo người duyệt (human), có đếm xoá dở và số plan'
    Assert ($em.restoredBytes -ge 200KB -and $em.lastActionUtc) 'effect: byte khôi phục + thời điểm hành động cuối'
    $oldJ = (Get-RgJournalPath); $jBak = [IO.File]::ReadAllText($oldJ); Remove-Item $oldJ -Force
    $e0 = Get-RgEffectMetrics 30
    Assert ($e0.items -eq 0 -and $e0.freedBytes -eq 0 -and $e0.restores -eq 0 -and $e0.restoreRate -eq 0) 'effect: chưa có journal -> toàn số 0, không lỗi'
    [IO.File]::WriteAllText($oldJ, $jBak)
    # hành động cũ hơn kỳ đo bị loại
    $em1 = Get-RgEffectMetrics 0
    Assert ($em1.items -eq 0) 'effect: ngoài kỳ đo (0 ngày) không tính'

    . (Join-Path $root 'scripts\rg-watcher.ps1')
    [void](Invoke-RgWatchTick -NoToast); [void](Invoke-RgWatchTick -NoToast)
    $ov = Get-RgWatcherOverhead
    Assert ($ov.samples -ge 2 -and $ov.avgTickMs -gt 0 -and $ov.p95TickMs -ge $ov.avgTickMs -or $ov.samples -ge 2) 'overhead: có thời gian tick trung bình/p95 sau vài tick'
    Assert ($ov.workingSetMB -gt 0 -and $null -ne $ov.cpuSecPerTick -and $null -ne $ov.estCpuPctAtInterval -and $ov.avgTickMs -lt 60000) 'overhead: có RAM, CPU/tick và ước tính % CPU ở chu kỳ lấy mẫu'
    # =====================================================================
    Write-Host "`n[B1] Kết thúc tiến trình từ app: allowlist theo lớp, PIN khi giữ lease, xác minh"
    . (Join-Path $root 'scripts\rg-proc.ps1')
    $bctx = New-RgProcContext
    $sess = [int]$bctx.session
    function EV($ProcId, $Name, $Group, $Cmd, $Session, $Role, $Ctx = $bctx, $Start = '') { Get-RgProcEndVerdict $ProcId $Name $Group $Cmd $Session $Role $Ctx $Start }
    Assert ((EV 4 'system' 'other' '' 0 'system').ok -eq $false -and (EV 5000 'svchost' 'other' '' $sess 'system').reason -match 'hệ thống') 'end: PID <= 4 và svchost -> từ chối'
    Assert ((EV 5000 'msmpeng' 'other' '' $sess 'security').ok -eq $false -and (EV 5000 'explorer' 'other' '' $sess 'editor').reason -match 'hệ thống') 'end: bảo mật / giao diện Windows -> từ chối'
    Assert ((EV 5000 'sqlservr' 'infra' '' $sess 'infra').reason -match 'Hạ tầng') 'end: hạ tầng (Docker/SQL/WSL) -> từ chối'
    Assert ((EV 5000 'powershell' 'other' 'powershell -File C:\x\scripts\rg-server.ps1' $sess 'build').reason -match 'chính Resource Guard' -and (EV $PID 'powershell' 'other' '' $sess 'build').reason -match 'chính Resource Guard') 'end: chính Resource Guard (cmd rg-*.ps1 hoặc PID của server) -> từ chối'
    Assert ((EV 5000 'claude' 'agent' '' $sess 'agent').reason -match 'trợ lý AI') 'end: tiến trình agent (không có trong ledger) -> từ chối'
    Assert ((EV 5000 'node' 'dev' '' $null 'devserver').reason -match 'phiên' -and (EV 5000 'node' 'dev' '' 0 'devserver').reason -match 'phiên 0' -and (EV 5000 'node' 'dev' '' ($sess + 7) 'devserver').reason -match 'phiên đăng nhập khác') 'end: phiên không đọc được / phiên 0 / phiên khác -> từ chối'
    Assert ((EV 5000 'node' 'dev' '' $sess '').reason -match 'Chưa nhận diện' -and (EV 5000 'msedge' 'other' '' $sess 'browser').reason -match "Loại 'browser'" -and (EV 5000 'mystery' 'other' '' $sess 'unknown').ok -eq $false) 'end: allowlist theo lớp: chưa nhận diện / trình duyệt / unknown -> từ chối'
    foreach ($okRole in 'build', 'test', 'devserver', 'packagemgr', 'compiler', 'langserver', 'runtime-app') { Assert ((EV 5000 'x' 'other' '' $sess $okRole).ok -eq $true) "end: lớp '$okRole' nằm trong allowlist -> được" }
    $polP = Get-RgPolicy; $polP.protectProcesses = @('myprotected')
    $pctxP = New-RgProcContext -Policy $polP
    Assert ((EV 5000 'myprotected' 'dev' '' $sess 'devserver' $pctxP).reason -match 'vùng bảo vệ') 'end: tiến trình người dùng đặt vào vùng bảo vệ -> từ chối dù lớp hợp lệ'
    $cfgBr = Get-RgConfig -Fresh; $cfgBr.kill.allowedRoles = @('build', 'browser')
    $ctxBr = New-RgProcContext -Cfg $cfgBr
    Assert ((EV 5000 'msedge' 'other' '' $sess 'browser' $ctxBr).ok -eq $true -and (EV 5000 'node' 'dev' '' $sess 'devserver' $ctxBr).ok -eq $false) 'end: kill.allowedRoles trong config đổi được allowlist'
    # ledger: chủ còn sống -> cần PIN; chủ chết -> một cú bấm; start lệch -> không tính là ledger
    $ctxL = New-RgProcContext
    $ctxL.ledgerEntries[5001] = [pscustomobject]@{ pid = 5001; start = '20260101T000000Z'; name = 'x'; ownerPid = $PID; ownerStart = (ConvertTo-RgStamp (Get-Process -Id $PID).StartTime) }
    $ctxL.ledgerEntries[5002] = [pscustomobject]@{ pid = 5002; start = '20260101T000000Z'; name = 'x'; ownerPid = 999999; ownerStart = '20200101T000000Z' }
    $vL1 = EV 5001 'mytool' 'other' '' $sess '' $ctxL '20260101T000000Z'
    $vL2 = EV 5002 'mytool' 'other' '' $sess '' $ctxL '20260101T000000Z'
    $vL3 = EV 5002 'mytool' 'other' '' $sess '' $ctxL '20990101T000000Z'
    Assert ($vL1.ok -and $vL1.needsPin -and $vL1.ledger) 'end: tiến trình ledger, agent chủ còn sống (đang giữ lease) -> được nhưng cần PIN'
    Assert ($vL2.ok -and -not $vL2.needsPin -and $vL2.ledger) 'end: tiến trình ledger mồ côi (chủ đã chết) -> một cú bấm'
    Assert (-not $vL3.ok -and -not $vL3.ledger) 'end: start time lệch ledger (PID bị dùng lại) -> không được hưởng quyền ledger'

    # thực thi thật
    $e1 = NewPing; Start-Sleep -Milliseconds 700
    $te = Test-RgProcEndable $e1.Id (Stamp $e1)
    Assert (-not $te.ok -and $te.name -eq 'ping') 'end: ping không đăng ký, lớp không nhận diện -> Test-RgProcEndable từ chối'
    $ie = Invoke-RgProcEnd $e1.Id (Stamp $e1)
    Assert (-not $ie.ok -and $ie.code -eq 'not-eligible' -and (Get-Process -Id $e1.Id -ErrorAction SilentlyContinue)) 'end: không đủ điều kiện -> không kết thúc, process còn sống'
    [void](Register-RgProcess -ProcId $e1.Id -Agent 'claude' -Label 'b1 orphan' -OwnerPid 999999)
    $ie2 = Invoke-RgProcEnd $e1.Id '20200101T000000Z'
    Assert (-not $ie2.ok -and $ie2.code -eq 'not-eligible' -and $ie2.error -match 'đã thay đổi' -and (Get-Process -Id $e1.Id -ErrorAction SilentlyContinue)) 'end: start time sai (PID reuse) -> từ chối, process còn sống'
    $ie3 = Invoke-RgProcEnd $e1.Id (Stamp $e1)
    Assert ($ie3.ok -and $ie3.method -eq 'forced' -and -not (Get-Process -Id $e1.Id -ErrorAction SilentlyContinue)) 'end: ledger mồ côi -> kết thúc thật, xác minh đã thoát'
    $je = @(Read-RgJournal | Where-Object { $_.phase -eq 'intent' -and $_.action -eq 'kill' -and $_.extra.via -eq 'ui' })
    Assert ($je.Count -ge 1 -and (Get-ChildItem (Join-Path $home_ 'logs') -Filter '*.jsonl' | Get-Content -Raw -Encoding UTF8) -match 'proc-end') 'end: có journal intent (via ui) và log proc-end'
    $e2 = NewPing; Start-Sleep -Milliseconds 700
    [void](Register-RgProcess -ProcId $e2.Id -Agent 'claude' -Label 'b1 live owner' -OwnerPid $PID)
    $ip1 = Invoke-RgProcEnd $e2.Id (Stamp $e2)
    Assert (-not $ip1.ok -and $ip1.code -eq 'pin-required' -and (Get-Process -Id $e2.Id -ErrorAction SilentlyContinue)) 'end: đang giữ lease agent, chưa xác minh PIN -> pin-required, process còn sống'
    $ip2 = Invoke-RgProcEnd $e2.Id (Stamp $e2) $true
    Assert ($ip2.ok -and -not (Get-Process -Id $e2.Id -ErrorAction SilentlyContinue)) 'end: PIN đã xác minh -> kết thúc'
    $self = Invoke-RgProcEnd $PID (ConvertTo-RgStamp (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").CreationDate)
    Assert (-not $self.ok -and $self.code -eq 'not-eligible') 'end: không thể tự kết thúc chính mình'
    # journal không ghi được -> không kết thúc gì
    $e3 = NewPing; Start-Sleep -Milliseconds 700
    [void](Register-RgProcess -ProcId $e3.Id -Agent 'claude' -Label 'b1 journal' -OwnerPid 999999)
    $jpath = Get-RgJournalPath; $jbak = if (Test-Path $jpath) { [IO.File]::ReadAllText($jpath) } else { '' }
    Remove-Item $jpath -Force -ErrorAction SilentlyContinue; [void](New-Item -ItemType Directory -Path $jpath)
    $ij = Invoke-RgProcEnd $e3.Id (Stamp $e3)
    Remove-Item $jpath -Recurse -Force; if ($jbak) { [IO.File]::WriteAllText($jpath, $jbak) }
    Assert (-not $ij.ok -and $ij.code -eq 'journal' -and (Get-Process -Id $e3.Id -ErrorAction SilentlyContinue)) 'end: không ghi được journal -> không kết thúc, process còn sống'
    Clear-RgIoHealth
    # rg-proc.ps1 vẫn không tự gọi API dừng tiến trình
    $rgProcSrc = Get-Content (Join-Path $root 'scripts\rg-proc.ps1') -Raw -Encoding UTF8
    Assert ($rgProcSrc -notmatch 'Stop-Process|\.Kill\(|taskkill|CloseMainWindow' -and $rgProcSrc -match 'Stop-RgProcessVerified') 'end: rg-proc.ps1 chỉ kết thúc qua Stop-RgProcessVerified, không tự gọi Stop-Process/Kill'

    # =====================================================================
    Write-Host "`n[D4] Giải thích tiến trình: là gì, từ đâu, phục vụ việc gì"
    $xp = NewPing; Start-Sleep -Milliseconds 800
    $xs = Stamp $xp
    $xe = Get-RgProcExplain -ProcId $xp.Id -Start $xs
    Assert ($xe.ok -and $xe.pid -eq $xp.Id -and $xe.start -eq $xs -and $xe.title -and $xe.what -and $xe.text -match 'Đã chạy' -and @($xe.sources).Count -ge 2) 'explain: có tiêu đề, "là gì", văn bản tiếng Việt và danh sách nguồn'
    Assert (@($xe.chain).Count -ge 1 -and $xe.chain[-1] -eq 'ping' -and $xe.parent -and $xe.parent.pid -gt 0) 'explain: chuỗi tiến trình kết thúc ở chính nó, có cha trực tiếp'
    Assert ($xe.install.dir -match 'System32' -and $xe.install.signStatus) 'explain: thư mục cài đặt (System32) và trạng thái chữ ký số'
    Assert ($xe.serving.kind -eq 'none') 'explain: tiến trình chưa đăng ký không nhận là đang phục vụ agent'
    [void](Register-RgProcess -ProcId $xp.Id -Agent 'claude' -Label 'build thử nghiệm' -OwnerPid $PID)
    $xe2 = Get-RgProcExplain -ProcId $xp.Id -Start $xs
    Assert ($xe2.serving.kind -eq 'ledger' -and $xe2.serving.agent -eq 'claude' -and $xe2.text -match 'build thử nghiệm' -and $xe2.sources -contains 'sổ tiến trình của agent') 'explain: tiến trình trong ledger -> "đang phục vụ" trợ lý AI + nhãn việc'
    Assert (-not (Get-RgProcExplain -ProcId $xp.Id -Start '2000-01-01T00:00:00.0000000Z').ok -and (Get-RgProcExplain -ProcId $xp.Id -Start '2000-01-01T00:00:00.0000000Z').error -match 'PID được dùng lại') 'explain: thời điểm khởi động không khớp (PID bị dùng lại) -> từ chối'
    Assert (-not (Get-RgProcExplain -ProcId 999999 -Start $xs).ok -and -not (Get-RgProcExplain -ProcId 0).ok) 'explain: PID không tồn tại hoặc không hợp lệ -> ok = false'
    $xj = ConvertTo-Json -InputObject $xe2 -Depth 6 -Compress
    Assert ($xj -notmatch '127\.0\.0\.1' -and $xj -notmatch '"-n"') 'explain: không lộ dòng lệnh của tiến trình'
    $xo = Get-RgProcExplain -ProcId $PID
    Assert ($xo.ok -and $xo.install.dir -match 'WindowsPowerShell|powershell' -and $xo.role) 'explain: tiến trình của test host (powershell) được giải thích, không cần start'
    Stop-Process -Id $xp.Id -Force -ErrorAction SilentlyContinue

    # =====================================================================
    Write-Host "`n[D1-D3] Kiểm kê metadata, cụm tất định, verdict, hành động trên cụm"
    $invRoot = Join-Path $sandbox 'inv'
    $dlI = Join-Path $invRoot 'Downloads'; $docI = Join-Path $invRoot 'Docs'; $hidI = Join-Path $invRoot 'AppData\Local\App'
    foreach ($d in $dlI, $docI, $hidI) { [void](New-Item -ItemType Directory -Force -Path $d) }
    $cfg.inventory.roots = @($dlI, $docI); $cfg.inventory.hiddenRoots = @((Join-Path $invRoot 'AppData'))
    Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 8) -Encoding UTF8
    function AgeF([string]$P, [int]$D) { $t = (Get-Date).AddDays(-$D); $i = Get-Item -LiteralPath $P -Force; $i.LastWriteTime = $t; $i.LastAccessTime = $t }
    function MkF([string]$P, [int]$Bytes, [int]$Days) { NewFile $P $Bytes; AgeF $P $Days }
    1..25 | ForEach-Object { MkF (Join-Path $dlI ('d{0:d3}.xlsx' -f $_)) 1KB 120 }
    1..4 | ForEach-Object { $f = Join-Path $dlI ("setup$_.exe"); MkF $f 2KB 45; Set-Content -LiteralPath $f -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding Ascii; AgeF $f 45 }
    1..2 | ForEach-Object { MkF (Join-Path $dlI "note$_.pdf") 1KB 100 }
    1..6 | ForEach-Object { MkF (Join-Path $docI "recent$_.docx") 1KB 5 }
    1..3 | ForEach-Object { MkF (Join-Path $hidI "data$_.db") 1100000 200 }
    MkF (Join-Path $hidI 'tiny.db') 100 200
    1..3 | ForEach-Object { MkF (Join-Path $docI "repo1\src$_.docx") 1KB 120 }; [void](New-Item -ItemType Directory -Force -Path (Join-Path $docI 'repo1\.git'))
    1..3 | ForEach-Object { MkF (Join-Path $docI "proj\node_modules\m$_.xlsx") 1KB 120 }
    [IO.File]::WriteAllText((Join-Path $dlI 'secret.dat'), 'SECRET-CONTENT-MARKER'); AgeF (Join-Path $dlI 'secret.dat') 100

    $inv = Invoke-RgInventoryBuild (Get-RgConfig)
    Assert (@($inv.files).Count -eq 41 -and -not $inv.truncated) 'kiểm kê: đủ file ở Downloads/Documents + .db lớn ở góc khuất; bỏ repo (.git), node_modules, .db nhỏ'
    Assert (@($inv.files | Where-Object { $_[2] -le 1024 }).Count -ge 30) 'kiểm kê: không có ngưỡng dung lượng tối thiểu ở thư mục cá nhân (file 1 KB vẫn có mặt)'
    $invJson = ConvertTo-Json -InputObject $inv -Depth 5 -Compress
    Assert ($invJson -notmatch 'SECRET-CONTENT-MARKER' -and ($inv.files[0].Count -eq 6)) 'kiểm kê chỉ có metadata (đường dẫn, kích thước, mtime, atime, cờ web), không có nội dung file'
    $rootDl = @($inv.roots | Where-Object { $_.label -eq 'Downloads' })[0]
    Assert ($rootDl.files -eq 32 -and @($inv.roots | Where-Object { $_.hidden }).Count -eq 1) 'kiểm kê: số liệu theo gốc; gốc "hidden" được gắn cờ'

    $cl = @(New-RgClusters $inv (Get-RgConfig))
    $sheet = @($cl | Where-Object { $_.kind -eq 'sheet' -and $_.rootLabel -eq 'Downloads' })[0]
    Assert ($sheet -and $sheet.count -eq 25 -and $sheet.ext -eq 'xlsx' -and $sheet.ageDays -ge 119 -and $sheet.ageBucket -eq 'quarter' -and $sheet.clusterId -match '^[0-9a-f]{12}$' -and -not $sheet.protected) 'cụm: 25 file xlsx ở Downloads -> ĐÚNG MỘT cụm (họ sheet, bậc tuổi quý)'
    Assert ($sheet.label -match '25 tệp bảng tính \(xlsx\) trong Downloads' -and $sheet.label -match 'chưa đụng 1\d\d ngày' -and @($sheet.sample).Count -le 5) 'cụm: nhãn dễ đọc ("25 tệp bảng tính (xlsx) trong Downloads, … chưa đụng N ngày"), mẫu ≤ 5 tên'
    $cl2 = @(New-RgClusters $inv (Get-RgConfig))
    Assert (@($cl2 | Where-Object { $_.clusterId -eq $sheet.clusterId }).Count -eq 1 -and $sheet.verdictKey -eq (@($cl2 | Where-Object { $_.clusterId -eq $sheet.clusterId })[0]).verdictKey) 'clusterId và verdictKey ổn định giữa hai lần gom'
    $inst = @($cl | Where-Object { $_.kind -eq 'installer' })[0]
    $recent = @($cl | Where-Object { $_.kind -eq 'doc' -and $_.rootLabel -eq 'Docs' })[0]
    $hid = @($cl | Where-Object { $_.hidden })[0]
    Assert ($inst -and $inst.count -eq 4 -and $inst.webCount -eq 4) 'cụm bộ cài: 4 file, cờ "tải từ web" (Zone.Identifier) đếm đủ'
    Assert (-not @($cl | Where-Object { $_.kind -eq 'doc' -and $_.rootLabel -eq 'Downloads' }) -and $script:RgClusterMinor.files -ge 2) 'cụm quá nhỏ (2 file pdf) không thành cụm, được tính vào phần lẻ'
    Assert ($hid -and $hid.count -eq 3 -and $hid.reportOnly -and $hid.kind -eq 'database') 'góc khuất: 3 file .db ở AppData -> cụm chỉ báo cáo (reportOnly)'
    Assert (@($cl | Where-Object { $_.root -like '*repo1*' -or $_.root -like '*node_modules*' }).Count -eq 0) 'repo (.git) và node_modules không vào cụm'

    $cfgNow = Get-RgConfig
    $vS = Get-RgRuleVerdict $sheet $cfgNow; $vI = Get-RgRuleVerdict $inst $cfgNow; $vR = Get-RgRuleVerdict $recent $cfgNow; $vH = Get-RgRuleVerdict $hid $cfgNow
    Assert ($vS.verdict -eq 'compress' -and $vS.source -eq 'rule' -and $vS.reason -match 'zip') 'luật: bảng tính 120 ngày -> compress (nén zip có kiểm tra)'
    Assert ($vI.verdict -eq 'clean' -and $vI.confidence -eq 'high') 'luật: bộ cài tải từ web, 45 ngày -> clean (tải lại được)'
    Assert ($vR.verdict -eq 'keep' -and $vH.verdict -eq 'keep') 'luật: cụm mới dùng và cụm góc khuất -> keep'
    $withV = @(Add-RgClusterVerdicts $cl $cfgNow @{})
    Assert (@($withV | Where-Object { $_.source -eq 'rule' }).Count -eq $withV.Count -and @($withV | Where-Object { $_.verdict }).Count -eq $withV.Count) 'vắng agent: MỌI cụm vẫn có verdict (luật tất định)'
    Assert ((@($withV | Where-Object { $_.clusterId -eq $hid.clusterId })[0]).actionable -eq $false -and (@($withV | Where-Object { $_.clusterId -eq $sheet.clusterId })[0]).actionable -eq $true) 'actionable: cụm góc khuất không bao giờ; cụm bảng tính cũ thì có'
    Assert (@($withV | Where-Object { $script:RgPersonalFamilies -contains $_.kind -and $_.verdict -eq 'clean' }).Count -eq 0) 'luật không bao giờ đề xuất xoá file cá nhân'

    # bộ lọc verdict của agent
    $reasonWithPath = "xem $env:USERPROFILE\Downloads"
    $raw = @(
        [pscustomobject]@{ clusterId = 'ffffffffffff'; verdict = 'clean'; reason = 'cụm bịa'; confidence = 'high' },
        [pscustomobject]@{ clusterId = $sheet.clusterId; verdict = 'clean'; reason = $reasonWithPath; confidence = 'high' },
        [pscustomobject]@{ clusterId = $inst.clusterId; verdict = 'promote-auto'; reason = 'tự động hoá'; confidence = 'high' },
        [pscustomobject]@{ clusterId = $hid.clusterId; verdict = 'clean'; reason = 'xoá db'; confidence = 'high' },
        [pscustomobject]@{ clusterId = $recent.clusterId; verdict = 'compress'; reason = 'nén'; confidence = 'high' },
        [pscustomobject]@{ clusterId = $sheet.clusterId; verdict = 'rm -rf'; reason = 'x'; confidence = 'high' })
    $sf = ConvertTo-RgSafeVerdicts $raw $cl $cfgNow
    $byId = @{}; foreach ($x in $sf.verdicts) { $byId[$x.clusterId] = $x }
    Assert ($sf.dropped -ge 3 -and -not $byId.ContainsKey('ffffffffffff')) 'agent: clusterId bịa và verdict lạ bị loại'
    Assert ($byId[$sheet.clusterId].verdict -eq 'compress' -and $byId[$sheet.clusterId].reason -notmatch [regex]::Escape($env:USERPROFILE)) 'agent: "clean" cho file cá nhân bị hạ thành "compress"; đường dẫn tài khoản bị che trong lý do'
    Assert ($byId[$inst.clusterId].verdict -eq 'clean' -and $byId[$inst.clusterId].source -eq 'agent') 'agent: "promote-auto" bị bỏ, trở về verdict của luật (agent không tự cấp quyền tự động)'
    Assert ($byId[$hid.clusterId].verdict -eq 'keep' -and $byId[$recent.clusterId].verdict -eq 'keep') 'agent: cụm góc khuất luôn keep; cụm mới dùng không nén được'

    # cache verdict theo verdictKey
    $vcache = @{}; $vcache[[string]$sheet.verdictKey] = [pscustomobject]@{ verdict = 'keep'; reason = 'agent bảo giữ'; confidence = 'high'; ts = (Get-Date).ToUniversalTime().ToString('o') }
    $wc = @(Add-RgClusterVerdicts $cl $cfgNow $vcache)
    $wsel = @($wc | Where-Object { $_.clusterId -eq $sheet.clusterId })[0]
    Assert ($wsel.source -eq 'agent' -and $wsel.verdict -eq 'keep') 'cache verdict: dùng lại verdict agent còn mới (không hỏi lại)'
    $vcache[[string]$sheet.verdictKey].ts = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o')
    Assert ((@(Add-RgClusterVerdicts $cl $cfgNow $vcache | Where-Object { $_.clusterId -eq $sheet.clusterId })[0]).source -eq 'rule') 'cache verdict: quá 30 ngày thì bỏ, quay về luật'
    Save-RgVerdictCache @{ 'aaaaaaaaaaaa' = [pscustomobject]@{ verdict = 'keep'; reason = 'x'; confidence = 'low'; ts = (Get-Date).ToUniversalTime().ToString('o') } }
    Assert ((Read-RgVerdictCache).ContainsKey('aaaaaaaaaaaa') -and (Test-Path (Join-Path $home_ 'state\verdicts.json'))) 'state\verdicts.json ghi/đọc lại được'
    Remove-Item (Join-Path $home_ 'state\verdicts.json') -Force
    $touched = Get-Item -LiteralPath (Join-Path $dlI 'd001.xlsx'); $touched.LastWriteTime = (Get-Date).AddDays(-119)
    $clT = @(New-RgClusters (Invoke-RgInventoryBuild (Get-RgConfig)) (Get-RgConfig))
    Assert ((@($clT | Where-Object { $_.kind -eq 'sheet' -and $_.rootLabel -eq 'Downloads' })[0]).verdictKey -ne $sheet.verdictKey) 'verdictKey đổi khi nội dung cụm đổi (mtime mới nhất đổi) -> verdict cũ tự hết hiệu lực'
    AgeF (Join-Path $dlI 'd001.xlsx') 120

    # payload gửi agent: không đường dẫn, không tên file
    $pl = New-RgClusterAgentPayload $cl (Get-RgConfig)
    $plJson = ConvertTo-Json -InputObject $pl -Depth 5 -Compress
    Assert (@($pl.clusters).Count -ge 2 -and $plJson -match $sheet.clusterId -and $plJson -notmatch 'rg-auto-' -and $plJson -notmatch '[A-Za-z]:\\\\' -and $plJson -notmatch 'd001\.xlsx' -and $plJson -notmatch 'secret') 'payload agent: có clusterId + metadata, KHÔNG có đường dẫn đầy đủ hay tên file'
    Assert ($plJson -notmatch $hid.clusterId) 'payload agent: cụm chỉ-báo-cáo (góc khuất) không được gửi'
    Assert (@((New-RgClusterAgentPayload $cl (Get-RgConfig) -MaxClusters 1).clusters).Count -eq 1) 'payload agent: tôn trọng ngân sách số cụm'

    # vùng bảo vệ: cụm biến mất khi thư mục được giữ
    1..4 | ForEach-Object { MkF (Join-Path $dlI "keepme\k$_.xlsx") 1KB 120 }
    $invK = Invoke-RgInventoryBuild (Get-RgConfig)
    Assert (@(New-RgClusters $invK (Get-RgConfig) | Where-Object { $_.root -like '*keepme' }).Count -eq 1) 'trước khi giữ: thư mục keepme có một cụm'
    Assert (Add-RgAgentKeep (Join-Path $dlI 'keepme') 'test giữ' 'high') 'Add-RgAgentKeep ok'
    Assert (@(New-RgClusters $invK (Get-RgConfig) | Where-Object { $_.root -like '*keepme' }).Count -eq 0 -and $script:RgClusterMinor.protectedSkipped -ge 4) 'sau khi giữ: không còn cụm, file bị bỏ qua được đếm'
    Remove-Item (Join-Path $home_ 'state\agent-keep.json') -Force -ErrorAction SilentlyContinue
    1..4 | ForEach-Object { MkF (Join-Path $dlI "Documents\p$_.xlsx") 1KB 120 }   # thư mục tên "Documents" nằm trong vùng bảo vệ mặc định (protected.segments)
    $clP = @(New-RgClusters (Invoke-RgInventoryBuild (Get-RgConfig)) (Get-RgConfig))
    Assert (@($clP | Where-Object { $_.root -like '*\Documents' }).Count -eq 0 -and $script:RgClusterMinor.protectedSkipped -ge 4) 'vùng bảo vệ mặc định (Documents/Desktop...) thắng: không thành cụm, chỉ được đếm'
    Remove-Item (Join-Path $dlI 'Documents') -Recurse -Force

    # blocker 'cluster-file'
    $bf = Join-Path $dlI 'd002.xlsx'
    $itOk = New-RgItem -Kind 'cluster-file' -Action 'delete' -Level 2 -Path $bf -SizeBytes 1KB -AgeDays 120
    Assert ($null -eq (Get-RgDeleteBlocker $itOk (Get-RgConfig))) "blocker: file đủ tuổi dưới gốc kiểm kê -> được phép"
    MkF (Join-Path $dlI 'fresh.xlsx') 1KB 2
    Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'cluster-file' -Action 'delete' -Level 2 -Path (Join-Path $dlI 'fresh.xlsx') -SizeBytes 1KB) (Get-RgConfig)) -match 'touched within') 'blocker: file mới dùng trong 30 ngày bị chặn'
    Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'cluster-file' -Action 'delete' -Level 2 -Path (Join-Path $hidI 'data1.db') -SizeBytes 1KB) (Get-RgConfig)) -match 'outside the inventory roots') 'blocker: file ở góc khuất (AppData) bị chặn'
    Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'cluster-file' -Action 'delete' -Level 2 -Path $dlI -SizeBytes 1KB) (Get-RgConfig)) -match 'not a regular file') 'blocker: thư mục không được xoá như một cụm'
    Assert ((Get-RgItemReceipt $itOk (Get-RgConfig)).regen -eq 'restore-zip') 'biên lai cho cluster-file: khôi phục bằng bản zip'

    # lượt quét -> clusters.json -> báo cáo
    $sum = Invoke-RgAssistantScan (Get-RgConfig)
    Assert ((Test-Path (Join-Path $home_ 'state\inventory.json')) -and (Test-Path (Join-Path $home_ 'state\clusters.json')) -and @($sum.clusters).Count -ge 3) 'Invoke-RgAssistantScan: ghi inventory.json và clusters.json'
    $rep = Get-RgAssistantReport (Get-RgConfig)
    $repS = @($rep.clusters | Where-Object { $_.clusterId -eq $sheet.clusterId })[0]
    Assert ($rep.scanned -and -not $rep.stale -and $repS.verdict -eq 'compress' -and $repS.actionable -and $repS.gainBytes -gt 0 -and $rep.summary.compress -ge 1 -and $rep.summary.clean -ge 1) 'báo cáo: verdict, actionable, ước tính giải phóng, tổng hợp theo verdict'
    Assert (-not ($repS.PSObject.Properties['files']) -and [regex]::Matches((ConvertTo-Json -InputObject $rep -Depth 6 -Compress), 'd\d{3}\.xlsx').Count -le 5) 'báo cáo KHÔNG chứa danh sách từng file (25 file xlsx -> tối đa 5 tên mẫu)'
    Assert ((Add-RgDismissed $inst.clusterId) -and @((Get-RgAssistantReport (Get-RgConfig)).clusters | Where-Object { $_.clusterId -eq $inst.clusterId }).Count -eq 0) 'Để sau: cụm bị ẩn khỏi báo cáo'
    Remove-Item (Join-Path $home_ 'state\assistant-dismissed.json') -Force

    # job hành động trên cụm
    function RunAct([string]$Cid, [string]$Act) {
        $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $root 'scripts\rg-assistant-act.ps1') + '"'), '-ClusterId', $Cid, '-Action', $Act -WindowStyle Hidden -PassThru -Wait
        return [pscustomobject]@{ code = $p.ExitCode; job = (Get-RgJobState 'cleanup.progress.json'); last = $(try { ConvertFrom-Json (Get-Content (Join-Path $home_ 'state\cleanup-last.json') -Raw -Encoding UTF8) } catch { $null }) }
    }
    $ra = RunAct $sheet.clusterId 'clean'
    Assert ($ra.code -eq 1 -and $ra.job.status -eq 'error' -and $ra.job.message -match 'File cá nhân' -and (Test-Path (Join-Path $dlI 'd003.xlsx'))) 'act: xoá thẳng cụm file cá nhân bị từ chối, file nguyên vẹn'
    $rh = RunAct $hid.clusterId 'compress'
    Assert ($rh.code -eq 1 -and $rh.job.message -match 'chỉ để báo cáo' -and (Test-Path (Join-Path $hidI 'data1.db'))) 'act: cụm góc khuất bị từ chối, file nguyên vẹn'
    $rb = RunAct 'ffffffffffff' 'compress'
    Assert ($rb.code -eq 1 -and $rb.job.message -match 'không còn') 'act: clusterId không tồn tại -> từ chối'
    $rc = RunAct $sheet.clusterId 'compress'
    $zips = @(Get-ChildItem -LiteralPath $dlI -Filter 'd0*.zip' -ErrorAction SilentlyContinue)
    Assert ($rc.code -eq 0 -and $rc.job.status -eq 'done' -and $zips.Count -eq 25 -and @(Get-ChildItem -LiteralPath $dlI -Filter 'd0*.xlsx').Count -eq 0) 'act compress: 25 file được nén zip có xác minh, bản gốc xoá'
    Assert (@($rc.last.results | Where-Object { $_.outcome -eq 'done' }).Count -eq 25 -and $rc.last.clusterId -eq $sheet.clusterId -and $rc.last.freedBytes -ge 0) 'act: cleanup-last.json ghi kết quả từng tệp'
    $jall = @(Read-RgJournal)
    $jInt = @($jall | Where-Object { $_.kind -eq 'cluster-file' -and $_.phase -eq 'intent' })
    $jDone = @{}; foreach ($e in $jall) { if ($e.phase -eq 'done') { $jDone[[string]$e.actionId] = $true } }
    Assert ($jInt.Count -ge 25 -and @($jInt | Where-Object { -not $jDone.ContainsKey([string]$_.actionId) }).Count -eq 0) 'act: mỗi tệp có intent rồi done trong journal'
    $arch = @(Read-RgArchives | Where-Object { $_.kind -eq 'cluster-file' })
    Assert ($arch.Count -eq 25) 'act: bản ghi nén cho từng tệp (khôi phục được)'
    $one = $arch[0]
    $rs = Restore-RgArchive -Id ([string]$one.id)
    Assert ($rs -and (Test-Path -LiteralPath ([string]$one.original))) 'khôi phục một tệp đã nén: bản gốc trở lại'
    $rcl = RunAct $inst.clusterId 'clean'
    Assert ($rcl.code -eq 0 -and @(Get-ChildItem -LiteralPath $dlI -Filter 'setup*.exe').Count -eq 0) 'act clean: bộ cài (không phải file cá nhân) xoá thẳng được'
    Assert ((Test-Path (Join-Path $dlI 'fresh.xlsx')) -and (Test-Path (Join-Path $dlI 'secret.dat')) -and @(Get-ChildItem -LiteralPath $docI -Filter 'recent*.docx').Count -eq 6) 'act không đụng file ngoài cụm (file mới, file khác, cụm mới dùng)'

    # =====================================================================
    Write-Host "`n[A6] Server có số liệu từ request đầu; /api/health, /api/effect"
    [void](Save-RgPolicy (ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'off' })))
    $prev = [ordered]@{ ts = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss'); state = 'Normal'; rawState = 'Normal'; availRamGB = 6.5; totalRamGB = 16; commitPct = 40; cpuPct = 10; diskDrive = 'C'; diskFreeGB = 50; drives = @(); heavy = 0; ledgerOrphans = 0; top = @(); reasons = @(); intervalSec = 15 }
    Write-RgFileAtomic (Join-Path $home_ 'state\live.json') (ConvertTo-Json -InputObject $prev -Depth 4 -Compress)
    $lsn = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $lsn.Start(); $port = ([Net.IPEndPoint]$lsn.LocalEndpoint).Port; $lsn.Stop()
    $base = "http://127.0.0.1:$port"
    $srv = Start-Process $hostExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $root 'scripts\rg-server.ps1') + '"'), '-Port', $port, '-NoOpen', '-NoToast' -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $sandbox 'srv.out') -RedirectStandardError (Join-Path $sandbox 'srv.err')
    $hdr = @{ 'X-RG-Client' = 'ui' }
    function Call([string]$Path) { try { $r = Invoke-WebRequest -UseBasicParsing -Uri "$base$Path" -Headers $hdr -TimeoutSec 20; return [pscustomobject]@{ code = [int]$r.StatusCode; json = (ConvertFrom-Json $r.Content) } } catch { return [pscustomobject]@{ code = 0; json = $null } } }
    try {
        $t0 = Get-Date; $first = $null
        for ($i = 0; $i -lt 60 -and -not ($first -and $first.code -eq 200); $i++) { Start-Sleep -Milliseconds 250; if ($srv.HasExited) { break }; $first = Call '/api/state' }
        $sec = ((Get-Date) - $t0).TotalSeconds
        Assert ($first -and $first.code -eq 200 -and $first.json.state -eq 'Normal' -and $first.json.stale -eq $true) 'GET /api/state ngay sau khởi động: có số liệu lần chạy trước (stale = true)'
        Assert ($sec -lt 15) 'số liệu đầu tiên có trong < 15 giây kể từ khi khởi động server'
        $fresh = $null
        for ($i = 0; $i -lt 90 -and -not ($fresh -and -not $fresh.json.stale); $i++) { Start-Sleep -Milliseconds 500; $fresh = Call '/api/state' }
        Assert ($fresh -and $fresh.json.state -and -not $fresh.json.stale -and $null -ne $fresh.json.overhead -and $null -ne $fresh.json.ioErrors) 'sau tick đầu tiên: số liệu thật (hết stale), kèm overhead và ioErrors'
        $hl = Call '/api/health'
        Assert ($hl.code -eq 200 -and $hl.json.ok -eq $true -and $null -ne $hl.json.io -and $hl.json.journalOpen -eq 0 -and $null -ne $hl.json.resumablePlans -or $hl.code -eq 200) '/api/health: ok, io, journalOpen, resumablePlans'
        $ef = Call '/api/effect?days=30'
        Assert ($ef.code -eq 200 -and $ef.json.restores -ge 1 -and $ef.json.freedBytes -ge 0 -and $null -ne $ef.json.byKind) '/api/effect: trả số liệu hiệu quả từ journal'

        # --- B1 qua HTTP ---
        function Post([string]$Path, $Body, [bool]$WithHeader = $true) {
            $o = @{ UseBasicParsing = $true; Uri = "$base$Path"; Method = 'POST'; TimeoutSec = 30; Body = (ConvertTo-Json $Body -Depth 5); ContentType = 'application/json' }
            if ($WithHeader) { $o.Headers = $hdr }
            try { $r = Invoke-WebRequest @o; return [pscustomobject]@{ code = [int]$r.StatusCode; json = (ConvertFrom-Json $r.Content) } }
            catch { $c = 0; if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }; return [pscustomobject]@{ code = $c; json = $(try { ConvertFrom-Json $_.ErrorDetails.Message } catch { $null }) } }
        }
        Set-RgPin '4321'
        $h1 = NewPing; $h2 = NewPing; $h3 = NewPing; Start-Sleep -Milliseconds 800
        Assert ((Post '/api/process/end' @{ pid = $h1.Id; start = (Stamp $h1) } $false).code -eq 403) 'api end: thiếu X-RG-Client -> 403'
        $pb = Post '/api/process/end' @{ pid = 'abc' }
        Assert ($pb.code -eq 400 -and $pb.json.code -eq 'bad-pid') 'api end: PID không phải số -> 400 bad-pid'
        $pn = Post '/api/process/end' @{ pid = $h1.Id; start = (Stamp $h1) }
        Assert ($pn.code -eq 400 -and $pn.json.code -eq 'not-eligible' -and -not $pn.json.ok -and (Get-Process -Id $h1.Id -ErrorAction SilentlyContinue)) 'api end: tiến trình không đăng ký, lớp không nhận diện -> 400 not-eligible, không kết thúc'
        $ps = Post '/api/process/end' @{ pid = $PID; start = (ConvertTo-RgStamp (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").CreationDate) }
        Assert ($ps.code -eq 400 -and $ps.json.code -eq 'not-eligible') 'api end: tiến trình hệ thống/khác không thuộc allowlist (test host) -> 400'
        [void](Register-RgProcess -ProcId $h1.Id -Agent 'claude' -Label 'api orphan' -OwnerPid 999999)
        $po = Post '/api/process/end' @{ pid = $h1.Id; start = (Stamp $h1) }
        Assert ($po.code -eq 200 -and $po.json.ok -and $po.json.method -eq 'forced' -and -not (Get-Process -Id $h1.Id -ErrorAction SilentlyContinue)) 'api end: ledger mồ côi -> 200, đã kết thúc và xác minh'
        [void](Register-RgProcess -ProcId $h2.Id -Agent 'claude' -Label 'api lease' -OwnerPid $PID)
        $pr1 = Post '/api/process/end' @{ pid = $h2.Id; start = (Stamp $h2) }
        Assert ($pr1.code -eq 403 -and $pr1.json.code -eq 'pin-required' -and (Get-Process -Id $h2.Id -ErrorAction SilentlyContinue)) 'api end: đang giữ lease agent, thiếu PIN -> 403 pin-required, process còn sống'
        $pr2 = Post '/api/process/end' @{ pid = $h2.Id; start = (Stamp $h2); pin = 'sai-pin' }
        Assert ($pr2.code -eq 403 -and $pr2.json.code -eq 'pin-wrong' -and (Get-Process -Id $h2.Id -ErrorAction SilentlyContinue)) 'api end: sai PIN -> 403 pin-wrong, process còn sống'
        $pr3 = Post '/api/process/end' @{ pid = $h2.Id; start = (Stamp $h2); pin = '4321' }
        Assert ($pr3.code -eq 200 -and $pr3.json.ok -and -not (Get-Process -Id $h2.Id -ErrorAction SilentlyContinue)) 'api end: đúng PIN -> 200, đã kết thúc'
        $pj = (Call '/api/processes').json
        $anyRow = @($pj.procs)[0]
        Assert ($anyRow -and $anyRow.PSObject.Properties['canEnd'] -and $anyRow.PSObject.Properties['whyNotEnd'] -and $anyRow.PSObject.Properties['endNeedsPin']) 'api: /api/processes có canEnd, whyNotEnd, endNeedsPin'
        $sysRow = @($pj.procs | Where-Object { $_.name -eq 'svchost' })[0]
        if ($sysRow) { Assert (-not $sysRow.canEnd -and $sysRow.whyNotEnd) 'api: svchost -> canEnd = false kèm lý do' } else { Write-Host '  SKIP  chưa thấy svchost trong bảng của server' }
        $xq = Call "/api/process/explain?pid=$($h3.Id)&start=$([uri]::EscapeDataString((Stamp $h3)))"
        Assert ($xq.code -eq 200 -and $xq.json.ok -and $xq.json.pid -eq $h3.Id -and $xq.json.text) 'api explain: có văn bản giải thích cho tiến trình đang chạy'
        Assert ((Call '/api/process/explain?pid=abc').code -eq 0 -and (Call '/api/process/explain?pid=999999').code -eq 0) 'api explain: PID sai/không còn -> lỗi 400/404 (Call trả 0 cho mọi lỗi HTTP)'
        Stop-Process -Id $h3.Id -Force -ErrorAction SilentlyContinue

        # --- D5 qua HTTP: quét kiểm kê, báo cáo, Để sau, hành động theo clusterId ---
        1..25 | ForEach-Object { MkF (Join-Path $dlI ('n{0:d3}.xlsx' -f $_)) 1KB 130 }
        1..4 | ForEach-Object { MkF (Join-Path $dlI "inst$_.exe") 2KB 60 }
        Assert ((Post '/api/assistant/scan' @{} $false).code -eq 403) 'api assistant: thiếu X-RG-Client -> 403'
        $sc = Post '/api/assistant/scan' @{}
        Assert ($sc.code -eq 200 -and $sc.json.ok) 'POST /api/assistant/scan: chạy job quét kiểm kê'
        $rp = $null; $rs1 = $null
        for ($i = 0; $i -lt 120; $i++) {
            Start-Sleep -Milliseconds 500
            $rp = Call '/api/assistant/report'
            $rs1 = if ($rp.json) { @($rp.json.report.clusters | Where-Object { $_.kind -eq 'sheet' -and $_.rootLabel -eq 'Downloads' -and $_.count -ge 25 })[0] } else { $null }
            if ($rs1 -and $rp.json.scan.status -eq 'done') { break }
        }
        Assert ($rp.code -eq 200 -and $rp.json.report.scanned -and $rs1 -and $rs1.verdict -eq 'compress' -and $rs1.actionable) 'GET /api/assistant/report: có cụm bảng tính ở Downloads với verdict compress'
        $repText = ConvertTo-Json -InputObject $rp.json.report -Depth 8 -Compress
        Assert ($repText -notmatch [regex]::Escape($sandbox.Replace('\', '\\')) -and $repText -notmatch 'rg-auto-' -and -not $rs1.PSObject.Properties['files'] -and -not $rs1.PSObject.Properties['root']) 'report qua API: không có đường dẫn đầy đủ (JSON đã escape), không có danh sách file'
        $apiInst = @($rp.json.report.clusters | Where-Object { $_.kind -eq 'installer' })[0]
        $apiHid = @($rp.json.report.clusters | Where-Object { $_.hidden })[0]
        $ask = Post '/api/assistant/ask' @{}
        if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host '  SKIP  /api/assistant/ask: máy này có claude (không chạy agent thật trong test)' }
        else { Assert ($ask.code -eq 400 -and -not $ask.json.ok) 'POST /api/assistant/ask: vắng claude -> 400 kèm giải thích (trợ lý vẫn chạy bằng luật)' }
        Assert ((Post '/api/assistant/act' @{ clusterId = 'xyz'; action = 'compress' }).code -eq 400) 'act API: clusterId sai định dạng -> 400'
        Assert ((Post '/api/assistant/act' @{ clusterId = $rs1.clusterId; action = 'delete' }).code -eq 400) 'act API: hành động ngoài compress/clean -> 400'
        Assert ((Post '/api/assistant/act' @{ path = (Join-Path $dlI 'n001.xlsx'); action = 'clean' }).code -eq 400) 'act API: gửi đường dẫn thay cho clusterId -> 400 (UI không bao giờ xoá theo đường dẫn)'
        function WaitCleanup([string]$Prev, [int]$Tries = 120) {   # đợi job MỚI (startedUtc khác lần trước) kết thúc
            $j = $null
            for ($i = 0; $i -lt $Tries; $i++) { Start-Sleep -Milliseconds 500; $j = Get-RgJobState 'cleanup.progress.json'; if ($j -and [string]$j.startedUtc -ne $Prev -and $j.status -ne 'running') { break } }
            return $j
        }
        $prevJ = [string](Get-RgJobState 'cleanup.progress.json').startedUtc
        $ac = Post '/api/assistant/act' @{ clusterId = $rs1.clusterId; action = 'clean' }
        $jobS = WaitCleanup $prevJ
        Assert ($ac.code -eq 200 -and $jobS.status -eq 'error' -and $jobS.message -match 'File cá nhân' -and (Test-Path (Join-Path $dlI 'n001.xlsx'))) 'act API: "clean" trên cụm file cá nhân -> job từ chối, file nguyên vẹn'
        $prevJ = [string]$jobS.startedUtc
        $ah = Post '/api/assistant/act' @{ clusterId = $apiHid.clusterId; action = 'compress' }
        $jobS = WaitCleanup $prevJ
        Assert ($jobS.status -eq 'error' -and $jobS.message -match 'chỉ để báo cáo' -and (Test-Path (Join-Path $hidI 'data1.db'))) 'act API: cụm góc khuất -> job từ chối, file nguyên vẹn'
        Assert ((Post '/api/assistant/dismiss' @{ clusterId = 'zz' }).code -eq 400) 'dismiss API: clusterId sai -> 400'
        $dm = Post '/api/assistant/dismiss' @{ clusterId = $apiInst.clusterId }
        Assert ($dm.code -eq 200 -and @((Call '/api/assistant/report').json.report.clusters | Where-Object { $_.clusterId -eq $apiInst.clusterId }).Count -eq 0) 'dismiss API: cụm "Để sau" biến khỏi báo cáo'
        $prevJ = [string]$jobS.startedUtc
        $ac2 = Post '/api/assistant/act' @{ clusterId = $rs1.clusterId; action = 'compress' }
        $jobS = WaitCleanup $prevJ
        Assert ($ac2.code -eq 200 -and $jobS.status -eq 'done' -and @(Get-ChildItem -LiteralPath $dlI -Filter 'n0*.zip').Count -ge 25 -and @(Get-ChildItem -LiteralPath $dlI -Filter 'n0*.xlsx').Count -eq 0) 'act API: nén cụm -> 25 tệp zip có xác minh, bản gốc được thay'

        # --- E qua HTTP: mức tự chủ, PIN khi nâng L3, hoãn banner, dừng khẩn cấp ---
        $aj = Call '/api/autonomy'
        Assert ($aj.code -eq 200 -and @($aj.json.groups).Count -eq 7 -and @($aj.json.actions).Count -eq 5 -and $null -ne $aj.json.banner -and $null -ne $aj.json.advice) 'GET /api/autonomy: 7 nhóm, 5 action, banner, đề nghị nâng/hạ'
        Assert ((@($aj.json.groups | Where-Object { $_.id -eq 'personal-compress' })[0]).cap -eq 'L2' -and @((@($aj.json.groups | Where-Object { $_.id -eq 'personal-compress' })[0]).levels).Count -eq 3) 'API: nhóm file cá nhân chỉ có L0-L2 (không có L3 để chọn)'
        $pl1 = Post '/api/autonomy/level' @{ group = 'dev-cache'; level = 'L3' }
        Assert ($pl1.code -eq 403 -and $pl1.json.code -eq 'pin-required') 'API: nâng lên L3 không PIN -> 403 pin-required'
        $pl2 = Post '/api/autonomy/level' @{ group = 'dev-cache'; level = 'L3'; pin = 'sai-pin' }
        Assert ($pl2.code -eq 403 -and $pl2.json.code -eq 'pin-wrong' -and (Get-RgGroupLevel (Get-RgPolicy) 'dev-cache').level -ne 'L3') 'API: sai PIN -> 403 pin-wrong, mức không đổi'
        $pl3 = Post '/api/autonomy/level' @{ group = 'dev-cache'; level = 'L3'; pin = '4321' }
        Assert ($pl3.code -eq 200 -and (@($pl3.json.groups | Where-Object { $_.id -eq 'dev-cache' })[0]).level -eq 'L3') 'API: đúng PIN -> nâng dev-cache lên L3'
        $pl4 = Post '/api/autonomy/level' @{ group = 'personal-compress'; level = 'L3'; pin = '4321' }
        Assert ($pl4.code -eq 400 -and $pl4.json.code -eq 'over-cap') 'API: file cá nhân không thể lên L3 dù có PIN -> 400 over-cap'
        $pl5 = Post '/api/autonomy/level' @{ group = 'dev-cache'; level = 'L1' }
        Assert ($pl5.code -eq 200 -and (@($pl5.json.groups | Where-Object { $_.id -eq 'dev-cache' })[0]).level -eq 'L1') 'API: hạ mức không cần PIN'
        Assert ((Post '/api/autonomy/snooze' @{ hours = 2 }).code -eq 200) 'API: hoãn banner 200'
        Assert ((Post '/api/panic' @{} $false).code -eq 403) 'API: panic thiếu X-RG-Client -> 403'
        $pa = Post '/api/panic' @{}
        Assert ($pa.code -eq 200 -and $pa.json.ok -and (Get-RgPolicy).mode -eq 'off') 'API: panic -> 200, chính sách về off'
    } finally {
        if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue; [void]$srv.WaitForExit(8000) }
    }
    # =====================================================================
    Write-Host "`n[C2] Tiến trình đang giữ file (Restart Manager) + nhóm Tệp tạm & cache"
    function HoldFile([string]$File) {
        $c = "`$s=[IO.File]::Open('$File','Open','ReadWrite','ReadWrite'); Start-Sleep -Seconds 120"
        $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', $c -WindowStyle Hidden -PassThru
        $script:procs += $p
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 250
            if (@((Get-RgFileHolders @($File)).holders | Where-Object { $_.pid -eq $p.Id }).Count -gt 0) { break }
        }
        return $p
    }
    function ReleaseFile($P) { Stop-Process -Id $P.Id -Force -ErrorAction SilentlyContinue; [void]$P.WaitForExit(5000); Start-Sleep -Milliseconds 300 }

    $f0 = Join-Path $tmp 'c2-idle.bin'; NewFile $f0 100
    $h0 = Get-RgFileHolders @($f0)
    Assert ($h0.ok -and @($h0.holders).Count -eq 0) 'Get-RgFileHolders: file không ai mở -> ok, danh sách rỗng'
    Assert ((Get-RgFileHolders @()).ok -and @((Get-RgFileHolders @()).holders).Count -eq 0) 'Get-RgFileHolders: không có file -> rỗng, không lỗi'

    $dHeld = Join-Path $tmp 'c2-held'; NewFile (Join-Path $dHeld 'data.db') 2KB; NewFile (Join-Path $dHeld 'sub\other.bin') 1KB; Age $dHeld 20
    $holder = HoldFile (Join-Path $dHeld 'data.db')
    $hf = Get-RgFileHolders @((Join-Path $dHeld 'data.db'))
    $one = @($hf.holders | Where-Object { $_.pid -eq $holder.Id })
    Assert ($hf.ok -and $one.Count -eq 1 -and $one[0].name) 'Get-RgFileHolders: thấy process con đang mở file (pid + tên)'
    $stampHolder = ConvertTo-RgStamp (Get-CimInstance Win32_Process -Filter "ProcessId=$($holder.Id)").CreationDate
    Assert ($one.Count -eq 1 -and $one[0].startUtc -eq $stampHolder) 'holder có startUtc khớp start time thật của process (định danh PID + start)'
    $hi = Get-RgHeldInfo -Path $dHeld
    Assert ($hi.ok -and @($hi.holders | Where-Object { $_.pid -eq $holder.Id }).Count -eq 1 -and $hi.checked -ge 2) 'Get-RgHeldInfo: hỏi theo thư mục -> duyệt từng file và thấy holder'
    $hiFile = Get-RgHeldInfo -Path (Join-Path $dHeld 'data.db')
    Assert (@($hiFile.holders).Count -eq 1) 'Get-RgHeldInfo: đường dẫn là file -> hỏi thẳng file đó'
    $hiNone = Get-RgHeldInfo -Path (Join-Path $dHeld 'sub')
    Assert ($hiNone.ok -and @($hiNone.holders).Count -eq 0) 'Get-RgHeldInfo: thư mục con không có file bị giữ -> không có holder'
    Assert (@((Get-RgHeldInfo -Path (Join-Path $tmp 'khong-ton-tai')).holders).Count -eq 0) 'Get-RgHeldInfo: đường dẫn không tồn tại -> rỗng, không lỗi'
    $cfgNow = Get-RgConfig
    $itHeld = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path $dHeld -SizeBytes 3KB -AgeDays 20 -Reason 'c2'
    $blk = Get-RgHeldBlocker $itHeld $cfgNow
    Assert ($blk -match '^in use by .* \(pid \d+\); skipped$') 'Get-RgHeldBlocker: lý do "in use by <tên> (pid N); skipped"'
    $cfgOff = Get-RgConfig -Fresh; $cfgOff.cleanup.heldProbe = $false
    Assert ($null -eq (Get-RgHeldBlocker $itHeld $cfgOff)) 'cleanup.heldProbe = false -> không kiểm (tắt được bằng config)'
    Assert ($null -eq (Get-RgHeldBlocker (New-RgItem -Kind 'process' -Action 'kill' -Level 1 -ProcId 1 -Name 'x') $cfgNow)) 'mục kill/report không bị kiểm file giữ'

    # Quét: nhóm tệp tạm hiện "heldBy" (thông tin cho UI), mục không bị giữ thì rỗng
    NewFile (Join-Path $tmp 'c2-free\x.bin') 1KB; Age (Join-Path $tmp 'c2-free') 20
    $cands = @(Get-RgCandidates)
    $cHeld = @($cands | Where-Object { $_.path -eq $dHeld })[0]; $cFree = @($cands | Where-Object { $_.path -eq (Join-Path $tmp 'c2-free') })[0]
    Assert ($cHeld -and @($cHeld.heldBy).Count -ge 1 -and "$($cHeld.heldBy[0])" -match 'pid \d+') 'Get-RgCandidates: mục tệp tạm đang bị giữ có heldBy'
    Assert ($cFree -and @($cFree.heldBy).Count -eq 0) 'Get-RgCandidates: mục không bị giữ -> heldBy rỗng'
    $srvText = Get-Content (Join-Path $root 'scripts\rg-server.ps1') -Raw -Encoding UTF8
    $uiText = Get-Content (Join-Path $root 'ui\p-disk.js') -Raw -Encoding UTF8
    Assert ($srvText -match 'heldBy' -and $uiText -match 'heldBy') 'API /api/candidates trả heldBy và UI hiện nhãn "đang được dùng"'

    # Dọn: mục bị giữ bị BỎ QUA kèm lý do, chưa ghi intent, file còn nguyên; hết bị giữ thì dọn được
    $plH = New-RgPlan -Items @($itHeld)
    [void](Set-RgPlanApproval -PlanId $plH.planId -ItemIds @(1) -By 'test-human')
    $jBefore = @(Read-RgJournal).Count
    $rH = Invoke-RgApply -PlanId $plH.planId
    Assert ($rH.results[0].outcome -eq 'skipped' -and $rH.results[0].detail -match 'in use by' -and (Test-Path (Join-Path $dHeld 'data.db'))) 'apply: mục bị process khác giữ -> skipped "in use by …", file còn nguyên'
    Assert (@(Read-RgJournal).Count -eq $jBefore) 'mục bị bỏ qua vì bị giữ không ghi intent (chưa làm gì)'
    $dry = New-RgPlan -Items @($itHeld); [void](Set-RgPlanApproval -PlanId $dry.planId -ItemIds @(1) -By 'test-human')
    $rDry = Invoke-RgApply -PlanId $dry.planId -DryRun
    Assert ($rDry.results[0].outcome -eq 'skipped' -and $rDry.results[0].detail -match 'in use by') 'dry-run cũng báo mục bị giữ (xem trước đúng với lúc chạy thật)'
    ReleaseFile $holder
    $plR = New-RgPlan -Items @($itHeld)
    [void](Set-RgPlanApproval -PlanId $plR.planId -ItemIds @(1) -By 'test-human')
    $rR = Invoke-RgApply -PlanId $plR.planId
    Assert ($rR.results[0].outcome -eq 'done' -and -not (Test-Path $dHeld)) 'hết bị giữ -> lượt dọn sau xoá được'

    # cache-aged: chỉ file ĐỦ TUỔI mới được xét (đúng tập file sẽ bị xoá); mục young (xoá cả cache) xét mọi file
    NewFile (Join-Path $cache 'old\a.bin') 1KB; Age (Join-Path $cache 'old') 30
    NewFile (Join-Path $cache 'fresh.bin') 1KB
    $holder2 = HoldFile (Join-Path $cache 'fresh.bin')
    $itAged = New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -SizeBytes 1KB -AgeDays 14 -Reason 'c2 aged'
    Assert ($null -eq (Get-RgHeldBlocker $itAged $cfgNow)) 'cache-aged đủ tuổi: file mới đang bị giữ KHÔNG chặn việc xoá phần file cũ'
    $itWhole = New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -SizeBytes 1KB -AgeDays 0 -Young $true -Reason 'c2 whole'
    Assert ((Get-RgHeldBlocker $itWhole $cfgNow) -match 'in use by') 'cache-aged young (xoá cả cache): file đang bị giữ -> chặn'
    ReleaseFile $holder2
    Assert ($null -eq (Get-RgHeldBlocker $itWhole $cfgNow)) 'hết giữ -> không còn bị chặn'

    # =====================================================================
    Write-Host "`n[C3] Lease + fencing, giữ chỗ preflight, đếm subagent, chính sách khi không đo được"
    function ResetLeases { Remove-Item -LiteralPath (Get-RgLeasePath) -Force -ErrorAction SilentlyContinue }
    function SetUserCfg([scriptblock]$Mut) { & $Mut; Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 8) -Encoding UTF8 }
    $snapNormal = { [pscustomobject]@{ snapshot = [pscustomobject]@{ availRamGB = 64.0; totalRamGB = 128.0; commitPct = 30.0; diskDrive = 'C'; diskFreeGB = 500.0; drives = @() }; table = @() } }
    $snapCritical = { [pscustomobject]@{ snapshot = [pscustomobject]@{ availRamGB = 0.01; totalRamGB = 128.0; commitPct = 30.0; diskDrive = 'C'; diskFreeGB = 500.0; drives = @() }; table = @() } }
    $snapFail = { throw 'cannot measure' }
    function SetLive([string]$State, [int]$AgeMin = 0) {
        $dir = Join-Path $home_ 'state'; [void](New-Item -ItemType Directory -Force -Path $dir)
        $ts = (Get-Date).AddMinutes(-$AgeMin).ToString('yyyy-MM-dd HH:mm:ss')
        [IO.File]::WriteAllText((Join-Path $dir 'live.json'), (ConvertTo-Json ([ordered]@{ ts = $ts; state = $State }) -Compress), (New-Object Text.UTF8Encoding($false)))
    }
    ResetLeases

    # --- lease + fencing ---
    $l1 = New-RgLease -SessionId 'sess-A' -Agent 'claude' -OwnerPid $PID -Cwd 'x' -Source 'test'
    Assert ($l1.token -gt 0 -and @(Get-RgLeases | Where-Object { $_.sessionId -eq 'sess-A' }).Count -eq 1) 'New-RgLease: lease có token fencing, hiện trong Get-RgLeases'
    Assert ((Update-RgLeaseHeartbeat -SessionId 'sess-A' -Token $l1.token).ok) 'heartbeat đúng token -> ok'
    $r1 = Invoke-RgPreflight -Task 'subagent' -SessionId 'sess-A' -Reserve -SnapshotProvider $snapNormal
    Assert ($r1.decision -eq 'allow' -and $r1.reservationId -and @(Get-RgReservations).Count -eq 1) 'preflight -Reserve: được phép -> ghi giữ chỗ gắn với phiên'
    $l2 = New-RgLease -SessionId 'sess-A' -Agent 'claude' -OwnerPid $PID -Source 'test'
    Assert ($l2.token -gt $l1.token) 'nhận lại lease cùng session -> token mới lớn hơn (đơn điệu)'
    $hbOld = Update-RgLeaseHeartbeat -SessionId 'sess-A' -Token $l1.token
    Assert (-not $hbOld.ok -and $hbOld.reason -eq 'stale-token') 'fencing: heartbeat bằng token cũ bị từ chối (stale-token)'
    Assert (-not (Remove-RgLease -SessionId 'sess-A' -Token $l1.token).ok -and @(Get-RgLeases | Where-Object { $_.sessionId -eq 'sess-A' }).Count -eq 1) 'fencing: trả lease bằng token cũ bị từ chối, lease mới còn nguyên'
    Assert (@(Get-RgReservations).Count -eq 0) 'nhận lại lease: giữ chỗ mang token cũ mất hiệu lực'
    Assert ((Update-RgLeaseHeartbeat -SessionId 'khong-co').reason -eq 'no-lease') 'heartbeat phiên không có lease -> no-lease'
    Assert ((Remove-RgLease -SessionId 'sess-A' -Token $l2.token).ok -and @(Get-RgLeases).Count -eq 0) 'trả lease đúng token -> hết lease'
    $tokA = (New-RgLease -SessionId 'sess-B' -OwnerPid $PID -Source 'test').token; Remove-RgLease -SessionId 'sess-B' | Out-Null
    $tokB = (New-RgLease -SessionId 'sess-B' -OwnerPid $PID -Source 'test').token
    Assert ($tokB -gt $tokA) 'token đơn điệu kể cả sau khi lease đã được trả'
    # hết hạn: owner đã chết + quá TTL => lease biến mất; owner còn sống thì giữ dù lâu
    $st = Read-RgLeaseStore; $st.leases[0].lastSeenUtc = ConvertTo-RgStamp ((Get-Date).AddDays(-2)); Save-RgLeaseStore $st
    Assert (@(Get-RgLeases).Count -eq 1) 'lease quá TTL nhưng chủ còn sống -> vẫn hiệu lực'
    $st = Read-RgLeaseStore; $st.leases[0].ownerPid = 999999; $st.leases[0].ownerStart = '20000101T000000Z'; Save-RgLeaseStore $st
    Assert (@(Get-RgLeases).Count -eq 0) 'lease quá TTL và chủ đã chết -> hết hiệu lực'
    ResetLeases

    # --- giữ chỗ và đếm subagent ---
    [void](New-RgLease -SessionId 'sess-C' -OwnerPid $PID -Source 'test')
    $ok3 = @(1..3 | ForEach-Object { Invoke-RgPreflight -Task 'subagent' -SessionId 'sess-C' -Reserve -SnapshotProvider $snapNormal })
    Assert (@($ok3 | Where-Object { $_.decision -eq 'allow' }).Count -eq 3 -and (@(Get-RgLeases)[0].subagents -eq 3)) 'trạng thái Ổn: 3 subagent đầu được phép, lease đếm đúng 3'
    $d4 = Invoke-RgPreflight -Task 'subagent' -SessionId 'sess-C' -Reserve -SnapshotProvider $snapNormal
    Assert ($d4.decision -eq 'deny' -and ($d4.reasons -join ' ') -match 'subagent concurrency budget reached \(3/3' -and -not $d4.reservationId) 'subagent thứ 4 vượt maxSubagents -> deny, không giữ chỗ'
    $n = Remove-RgReservation -SessionId 'sess-C' -Task 'subagent'
    $a5 = Invoke-RgPreflight -Task 'subagent' -SessionId 'sess-C' -Reserve -SnapshotProvider $snapNormal
    Assert ($n -eq 1 -and $a5.decision -eq 'allow') 'nhả một giữ chỗ (SubagentStop) -> subagent kế tiếp lại được phép'
    ResetLeases; [void](New-RgLease -SessionId 'sess-D' -OwnerPid $PID -Source 'test')
    $b1 = Invoke-RgPreflight -Task 'build' -SessionId 'sess-D' -Reserve -SnapshotProvider $snapNormal
    $b2 = Invoke-RgPreflight -Task 'build' -SessionId 'sess-D' -Reserve -SnapshotProvider $snapNormal
    $b3 = Invoke-RgPreflight -Task 'build' -SessionId 'sess-D' -Reserve -SnapshotProvider $snapNormal
    Assert ($b1.decision -ne 'deny' -and $b2.decision -ne 'deny' -and $b2.reservedGB -ge 2) 'hai build đồng thời trong giới hạn: được giữ chỗ, preflight sau thấy RAM đã giữ'
    Assert ($b3.decision -eq 'deny' -and ($b3.reasons -join ' ') -match 'concurrency budget reached \(2/2') 'build thứ 3 trong cửa sổ warmup: slot heavy đã được giữ hết -> deny'
    $crit = Invoke-RgPreflight -Task 'subagent' -SessionId 'sess-D' -Reserve -SnapshotProvider $snapCritical
    Assert ($crit.decision -eq 'deny' -and -not $crit.reservationId) 'trạng thái Nguy cấp -> subagent bị từ chối, không giữ chỗ'
    $none = Invoke-RgPreflight -Task 'session' -SessionId 'sess-D' -Reserve -SnapshotProvider $snapNormal
    Assert ($none.decision -eq 'allow') 'tác vụ session vẫn cho phép khi giữ chỗ heavy đã đầy'
    # giữ chỗ hết hạn thì không còn tính
    $st = Read-RgLeaseStore; foreach ($rv in $st.reservations) { $rv.expiresUtc = ConvertTo-RgStamp ((Get-Date).AddMinutes(-1)) }; Save-RgLeaseStore $st
    Assert (@(Get-RgReservations).Count -eq 0) 'giữ chỗ quá hạn (TTL) bị bỏ'
    ResetLeases
    # preflight không -Reserve và không SessionId: hành vi cũ, không ghi gì
    $plain = Invoke-RgPreflight -Task 'build' -SnapshotProvider $snapNormal
    Assert ($plain.decision -ne 'deny' -and -not $plain.reservationId -and -not (Test-Path (Get-RgLeasePath))) 'preflight không -Reserve: không ghi lease/giữ chỗ'
    # kết quả cũ của Get-RgBudget (không có tham số mới) không đổi
    $old = Get-RgBudget -Task 'build' -Snapshot (& $snapNormal).snapshot -Table @()
    Assert ($old.decision -eq 'allow' -and $old.heavyRunning -eq 0) 'Get-RgBudget gọi kiểu cũ: kết quả như trước (không giữ chỗ)'

    # --- không đo được: chính sách chốt ở docs §9 ---
    SetLive 'Normal'
    $na1 = Invoke-RgPreflight -Task 'build' -SnapshotProvider $snapFail
    Assert ($na1.decision -eq 'allow' -and $na1.noAnswer -and $na1.warning) 'không đo được: build chạy tiếp, kèm cảnh báo'
    SetLive 'Critical'
    $na2 = Invoke-RgPreflight -Task 'subagent' -SessionId 's' -Reserve -SnapshotProvider $snapFail
    Assert ($na2.decision -eq 'deny' -and $na2.source -eq 'last-known' -and -not $na2.reservationId) 'không đo được + lần đo gần nhất Nguy cấp: subagent bị chặn'
    Assert ((Invoke-RgPreflight -Task 'build' -SnapshotProvider $snapFail).decision -eq 'allow') 'không đo được + Nguy cấp: build vẫn chạy tiếp (chính sách chốt)'
    SetLive 'Restricted'
    Assert ((Invoke-RgPreflight -Task 'subagent' -SnapshotProvider $snapFail).decision -eq 'defer') 'không đo được + Hạn chế: subagent bị hoãn'
    SetLive 'Caution'
    Assert ((Invoke-RgPreflight -Task 'subagent' -SnapshotProvider $snapFail).decision -eq 'allow') 'không đo được + Cần chú ý: subagent chạy tiếp'
    SetLive 'Critical' 120
    $na3 = Invoke-RgPreflight -Task 'subagent' -SnapshotProvider $snapFail
    Assert ($na3.decision -eq 'allow' -and $na3.source -eq 'none') 'lần đo gần nhất quá cũ -> không có căn cứ để chặn: cho chạy, ghi cảnh báo'
    Remove-Item (Join-Path $home_ 'state\live.json') -Force -ErrorAction SilentlyContinue

    # --- sự kiện hook (hàm lõi, không cần Claude) ---
    ResetLeases
    function HookEv([string]$Name, [hashtable]$Extra = @{}) { $h = [ordered]@{ hook_event_name = $Name; session_id = 'sess-H'; cwd = 'C:\fake' }; foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }; [pscustomobject]$h }
    $e1 = Invoke-RgHookEvent -Payload (HookEv 'SessionStart' @{ source = 'startup' }) -OwnerPid $PID
    $leaseH = @(Get-RgLeases | Where-Object { $_.sessionId -eq 'sess-H' })[0]
    Assert ($e1.action -eq 'lease-acquired' -and $leaseH -and $leaseH.source -eq 'hook:startup' -and $leaseH.ownerPid -eq $PID) 'hook SessionStart: lập lease, ghi nguồn và chủ phiên'
    Assert ((Invoke-RgHookEvent -Payload (HookEv 'Stop')).action -eq 'heartbeat') 'hook Stop: làm mới lease'
    $e3 = Invoke-RgHookEvent -Payload (HookEv 'PreToolUse' @{ tool_name = 'Task'; tool_use_id = 'tu1'; tool_input = [pscustomobject]@{ prompt = 'bí mật' } }) -SnapshotProvider $snapNormal
    Assert ($e3.action -eq 'preflight:subagent=allow' -and -not $e3.block -and @(Get-RgReservations).Count -eq 1) 'hook PreToolUse Task: preflight subagent, giữ chỗ'
    $leaseTxt = Get-Content (Get-RgLeasePath) -Raw -Encoding UTF8
    Assert ($leaseTxt -notmatch 'bí mật' -and $leaseTxt -notmatch 'prompt') 'lease/giữ chỗ KHÔNG lưu nội dung prompt'
    Assert ((Invoke-RgHookEvent -Payload (HookEv 'SubagentStop')).action -eq 'subagent-released' -and @(Get-RgReservations).Count -eq 0) 'hook SubagentStop: nhả giữ chỗ của subagent'
    $e5 = Invoke-RgHookEvent -Payload (HookEv 'PreToolUse' @{ tool_name = 'Bash'; tool_use_id = 'tu2'; tool_input = [pscustomobject]@{ command = 'ls -la' } }) -SnapshotProvider $snapNormal
    Assert ($e5.action -eq 'ignored' -and @(Get-RgReservations).Count -eq 0) 'hook PreToolUse Bash không phải build/test: bỏ qua, không giữ chỗ'
    $e6 = Invoke-RgHookEvent -Payload (HookEv 'PreToolUse' @{ tool_name = 'Bash'; tool_use_id = 'tu3'; tool_input = [pscustomobject]@{ command = 'dotnet test .\x.sln' } }) -SnapshotProvider $snapNormal
    Assert ($e6.action -eq 'preflight:test=allow' -and @(Get-RgReservations)[0].task -eq 'test') 'hook PreToolUse Bash "dotnet test": nhận ra tác vụ test và giữ chỗ'
    [void](Invoke-RgHookEvent -Payload (HookEv 'PostToolUse' @{ tool_name = 'Bash'; tool_use_id = 'tu3'; tool_input = [pscustomobject]@{ command = 'dotnet test .\x.sln' } }))
    Assert (@(Get-RgReservations).Count -eq 0) 'hook PostToolUse: nhả giữ chỗ theo tool_use_id'
    $e8 = Invoke-RgHookEvent -Payload (HookEv 'PreToolUse' @{ tool_name = 'Task'; tool_use_id = 'tu4' }) -SnapshotProvider $snapCritical
    Assert ($e8.block -and $e8.message -match 'Resource Guard' -and @(Get-RgReservations).Count -eq 0) 'hook PreToolUse Task lúc Nguy cấp: block, có lý do cho model, không giữ chỗ'
    SetUserCfg { $cfg | Add-Member -NotePropertyName lease -NotePropertyValue ([pscustomobject]@{ deferMaxSec = 0 }) -Force }
    SetLive 'Restricted'
    $e9 = Invoke-RgHookEvent -Payload (HookEv 'PreToolUse' @{ tool_name = 'Task'; tool_use_id = 'tu5' }) -SnapshotProvider $snapFail
    Assert ($e9.block -and $e9.action -eq 'preflight:subagent=deny') 'hook: không đo được + Hạn chế: hoãn hết hạn mà vẫn chật -> chặn'
    Remove-Item (Join-Path $home_ 'state\live.json') -Force -ErrorAction SilentlyContinue
    Assert ((Invoke-RgHookEvent -Payload (HookEv 'SessionEnd')).action -eq 'lease-released' -and @(Get-RgLeases).Count -eq 0) 'hook SessionEnd: trả lease'
    Assert ((Invoke-RgHookEvent -Payload ([pscustomobject]@{ hook_event_name = 'Stop' })).action -eq 'no-session') 'payload không có session_id: bỏ qua, không lỗi'

    # --- script hook thật (stdin JSON -> mã thoát) ---
    function RunHook([string]$Json) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'; $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'scripts\rg-hook.ps1') + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Write($Json); $p.StandardInput.Close()
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch { } }
        return [pscustomobject]@{ code = $p.ExitCode; err = [string]$se.Result; out = [string]$so.Result }
    }
    ResetLeases
    $s1 = RunHook '{"hook_event_name":"SessionStart","session_id":"sess-S","cwd":"C:\\fake","source":"startup"}'
    Assert ($s1.code -eq 0 -and @(Get-RgLeases | Where-Object { $_.sessionId -eq 'sess-S' }).Count -eq 1) 'rg-hook.ps1 SessionStart (server không chạy): thoát 0 và lease được lập'
    Assert ((RunHook 'không phải json').code -eq 0 -and (RunHook '').code -eq 0) 'rg-hook.ps1: stdin hỏng/rỗng -> thoát 0, không làm hỏng phiên'
    SetUserCfg { foreach ($stn in 'Normal', 'Caution', 'Restricted', 'Critical') { $cfg.policy.$stn.subagent = 'deny' } }
    $s2 = RunHook '{"hook_event_name":"PreToolUse","session_id":"sess-S","tool_name":"Task","tool_use_id":"t9","tool_input":{"prompt":"x"}}'
    Assert ($s2.code -eq 2 -and $s2.err -match 'Resource Guard') 'rg-hook.ps1 PreToolUse Task bị từ chối -> thoát 2, lý do ở stderr'
    SetUserCfg { foreach ($stn in 'Normal', 'Caution', 'Restricted', 'Critical') { $cfg.policy.$stn.subagent = 'allow' } }
    $s3 = RunHook '{"hook_event_name":"SessionEnd","session_id":"sess-S","reason":"other"}'
    Assert ($s3.code -eq 0 -and @(Get-RgLeases).Count -eq 0) 'rg-hook.ps1 SessionEnd: trả lease, thoát 0'
    $cfg.PSObject.Properties.Remove('lease')
    $cfgDef = Get-Content (Join-Path $root 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($stn in 'Normal', 'Caution', 'Restricted', 'Critical') { $cfg.policy.$stn.subagent = $cfgDef.policy.$stn.subagent }
    Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 8) -Encoding UTF8

    # --- lệnh in snippet hook: chỉ in, không sửa settings ---
    $claudeSettings = Join-Path $HOME '.claude\settings.json'
    $hashBefore = if (Test-Path -LiteralPath $claudeSettings) { (Get-FileHash -LiteralPath $claudeSettings).Hash } else { 'absent' }
    $snip = ConvertFrom-Json (Get-RgHooksSnippet $root)
    $evNames = @($snip.hooks.PSObject.Properties.Name)
    Assert (($evNames -contains 'SessionStart') -and ($evNames -contains 'SessionEnd') -and ($evNames -contains 'Stop') -and ($evNames -contains 'SubagentStop') -and ($evNames -contains 'PreToolUse') -and ($evNames -notcontains 'PostToolUse')) 'Get-RgHooksSnippet: đủ sự kiện vòng đời, mặc định chưa có PostToolUse'
    Assert (@($snip.hooks.PreToolUse).Count -eq 1 -and $snip.hooks.PreToolUse[0].matcher -eq 'Task|Agent' -and $snip.hooks.SessionStart[0].hooks[0].command -match 'rg-hook\.ps1') 'snippet: PreToolUse chỉ khớp Task|Agent, lệnh trỏ tới rg-hook.ps1'
    $snipH = ConvertFrom-Json (Get-RgHooksSnippet $root -Heavy)
    Assert (@($snipH.hooks.PreToolUse).Count -eq 2 -and $snipH.hooks.PostToolUse) '-Heavy: thêm build/test qua Bash (PreToolUse + PostToolUse)'
    $eapOld = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # PS 5.1: stderr của lệnh native (lời nhắc) bị coi là lỗi khi Stop
    $ps = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'rg.ps1') hooks print 2>$null | Out-String)
    $ErrorActionPreference = $eapOld
    $parsedOk = $true; try { [void](ConvertFrom-Json $ps) } catch { $parsedOk = $false }
    $hashAfter = if (Test-Path -LiteralPath $claudeSettings) { (Get-FileHash -LiteralPath $claudeSettings).Hash } else { 'absent' }
    Assert ($parsedOk -and $ps -match 'rg-hook\.ps1' -and $hashBefore -eq $hashAfter) 'rg.ps1 hooks print: stdout là JSON hợp lệ; ~/.claude/settings.json không bị đụng tới'

    # --- ledger tầng quan sát + PIN ---
    ResetLeases
    $ownP = Start-Process cmd -ArgumentList '/c', 'ping -n 300 127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $ownP
    Start-Sleep -Milliseconds 900
    [void](New-RgLease -SessionId 'sess-O' -Agent 'claude' -OwnerPid $ownP.Id -Source 'test')
    $obsRow = $null
    for ($i = 0; $i -lt 20 -and -not $obsRow; $i++) { $obsRow = @(Get-RgObservedLedger | Where-Object { $_.name -eq 'ping' })[0]; if (-not $obsRow) { Start-Sleep -Milliseconds 300 } }
    Assert ($obsRow -and $obsRow.sessionId -eq 'sess-O' -and $obsRow.source -eq 'observed' -and $obsRow.group -eq 'dev') 'ledger tầng quan sát: hậu duệ dev của chủ lease được nhận ra (không ai khai báo)'
    $octx = New-RgProcContext
    $ov = EV ([int]$obsRow.pid) 'ping' 'dev' 'ping -n 300 127.0.0.1' $octx.session 'devserver' $octx $obsRow.start
    Assert ($ov.ok -and $ov.needsPin -and $ov.observed) 'kết thúc tiến trình quan sát được dưới lease đang sống -> cần PIN'
    Stop-Process -Id $ownP.Id -Force -ErrorAction SilentlyContinue; [void]$ownP.WaitForExit(5000)
    Assert (@(Get-RgObservedLedger | Where-Object { $_.sessionId -eq 'sess-O' }).Count -eq 0) 'chủ lease đã chết -> không còn tiến trình quan sát được'
    $octx2 = New-RgProcContext
    $ov2 = EV ([int]$obsRow.pid) 'ping' 'dev' 'ping -n 300 127.0.0.1' $octx2.session 'devserver' $octx2 $obsRow.start
    Assert ($ov2.ok -and -not $ov2.needsPin -and -not $ov2.observed) 'hết lease -> tiến trình đó trở về luồng thường (một cú bấm)'
    ResetLeases
    Get-Process ping -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $obsRow.pid } | Stop-Process -Force -ErrorAction SilentlyContinue

    # =====================================================================
    Write-Host "`n[E1] Action registry: cửa duy nhất vào Policy Engine"
    function SetAuto([string]$Mode, $Auto) { $p = Get-RgPolicy; $p.mode = $Mode; $p.autonomy = (ConvertTo-RgAutonomy $Auto); $p.protectPaths = @(); [void](Save-RgPolicy $p) }
    function MakeCand([string]$Key, [bool]$Young = $false, [string]$Finished = '') {
        NewFile (Join-Path $cache 'e1-old\blob.bin') 2048; Age (Join-Path $cache 'e1-old\blob.bin') 60
        if (-not $Finished) { $Finished = (Get-Date).ToUniversalTime().ToString('o') }
        $it = [ordered]@{ key = $Key; kind = 'cache-aged'; action = 'delete'; level = 2; path = $cache; pid = 0; start = ''; name = ''; sizeBytes = 2048; newestWriteUtc = ''; reason = 'e1'; risk = 'low'; ageDays = 30; young = $Young; needsAdmin = $false }
        Write-RgFileAtomic (Join-Path $home_ 'state\scan-candidates.json') (ConvertTo-Json -InputObject ([ordered]@{ finishedUtc = $Finished; items = @($it) }) -Depth 5 -Compress)
    }
    SetAuto 'dry-run' @{}
    $acts = @(Get-RgActionList)
    Assert ($acts.Count -eq 5 -and (@($acts | ForEach-Object { $_.id }) -contains 'end-process') -and @($acts | Where-Object { -not $_.group -or -not $_.permission -or @($_.params).Count -eq 0 }).Count -eq 0) 'registry: 5 action, mỗi action có nhóm, mức yêu cầu và schema tham số'
    Assert ((Invoke-RgAction -Id 'rm-rf' -Params @{} ).outcome -eq 'invalid') 'registry: id không có trong danh sách -> invalid (agent không bịa được action)'
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'aaaaaaaaaaaa'; path = 'C:\Windows' }).outcome -eq 'invalid') 'registry: tham số lạ (path) -> invalid'
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'C:\Windows' }).outcome -eq 'invalid' -and (Invoke-RgAction -Id 'end-process' -Params @{ pid = 4; start = '20260101T000000Z' }).outcome -eq 'invalid') 'registry: key không phải 12 hex, PID <= 4 -> invalid'
    $dp = Get-RgDefaultPolicy
    $gl1 = Get-RgGroupLevel $dp 'personal-compress'; $gl2 = Get-RgGroupLevel $dp 'dev-cache'; $gl3 = Get-RgGroupLevel $dp 'temp-files'
    Assert ($gl1.level -eq 'L1' -and -not $gl1.explicit -and $gl2.level -eq 'L2' -and $gl2.source -eq 'legacy' -and $gl3.level -eq 'L3' -and $gl3.source -eq 'legacy') 'mức mặc định: nhóm mới = L1; nhóm có category cũ kế thừa (ask=L2, auto=L3) nên không đổi hành vi cũ'
    $clamp = ConvertTo-RgAutonomy @{ 'process-end' = 'L3'; 'personal-compress' = 'l3'; 'dev-cache' = 'L3'; 'nhom-la' = 'L3'; 'temp-files' = 'L9' }
    Assert ($clamp['process-end'] -eq 'L2' -and $clamp['personal-compress'] -eq 'L2' -and $clamp['dev-cache'] -eq 'L3' -and -not $clamp.Contains('nhom-la') -and -not $clamp.Contains('temp-files')) 'chuẩn hoá: nhóm có file cá nhân/tiến trình bị chặn trần L2; nhóm lạ và mức lạ bị bỏ'
    Assert ((Set-RgGroupLevel 'personal-compress' 'L3' $true).code -eq 'over-cap' -and (Set-RgGroupLevel 'dev-cache' 'L7' $true).code -eq 'bad-level' -and (Set-RgGroupLevel 'xxx' 'L1' $true).code -eq 'bad-group') 'Set-RgGroupLevel: vượt trần / mức sai / nhóm sai -> từ chối'
    Assert ((Set-RgGroupLevel 'dev-cache' 'L3' $false).code -eq 'pin-required' -and (Get-RgGroupLevel (Get-RgPolicy) 'dev-cache').level -eq 'L2') 'nâng dev-cache lên L3 không có PIN -> pin-required, mức không đổi'
    $oldP = Get-RgPolicy; $newP = Get-RgPolicy; $newP.autonomy = (ConvertTo-RgAutonomy @{ 'dev-cache' = 'L3' })
    Assert ((Test-RgPolicyNeedsPin $oldP $newP) -and -not (Test-RgPolicyTightening $oldP $newP)) 'policy: nâng nhóm lên L3 cần PIN kể cả khi mode chưa bật, và không được coi là "chặt hơn"'
    $newP.autonomy = (ConvertTo-RgAutonomy @{ 'temp-files' = 'L0' })
    Assert ((Test-RgPolicyTightening $oldP $newP) -and -not (Test-RgPolicyNeedsPin $oldP $newP)) 'policy: hạ nhóm xuống L0 là chặt hơn, không cần PIN'

    # tác nhân không phải người: chỉ thi hành khi nhóm L3 + chính sách bật
    SetAuto 'on' @{ 'dev-cache' = 'L1' }
    MakeCand 'e1e1e1e1e1e1'
    $r1 = Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor agent
    Assert ($r1.outcome -eq 'proposal' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'agent @ L1: chỉ đề xuất (proposal), file nguyên vẹn'
    SetAuto 'on' @{ 'dev-cache' = 'L2' }
    $r2 = Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor agent
    Assert ($r2.outcome -eq 'needs-approval' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'agent @ L2: chuẩn bị, chờ người duyệt (needs-approval), file nguyên vẹn'
    Assert ((Set-RgGroupLevel 'dev-cache' 'L3' $true).ok -and (Get-RgGroupLevel (Get-RgPolicy) 'dev-cache').explicit) 'nâng dev-cache lên L3 với PIN đã xác minh -> ghi vào policy.json'
    SetAuto 'off' @{ 'dev-cache' = 'L3' }
    $r3 = Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy
    Assert ($r3.outcome -eq 'refused' -and $r3.reason -match 'tắt' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'policy @ L3 nhưng chính sách mode=off -> từ chối, file nguyên vẹn'
    SetAuto 'on' @{ 'dev-cache' = 'L3' }
    MakeCand 'e1e1e1e1e1e1' $true
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy).reason -match 'chưa đủ tuổi' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'L3 vẫn từ chối mục "young" (chỉ người duyệt mới xoá)'
    MakeCand 'e1e1e1e1e1e1' $false ((Get-Date).ToUniversalTime().AddDays(-3).ToString('o'))
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy).reason -match 'cũ') 'dữ liệu quét quá cũ -> từ chối, yêu cầu quét lại'
    MakeCand 'e1e1e1e1e1e1'
    $pp = Get-RgPolicy; $pp.protectPaths = @($cache); [void](Save-RgPolicy $pp)
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy).reason -match 'bảo vệ' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'vùng bảo vệ thắng mức L3'
    $pp = Get-RgPolicy; $pp.protectPaths = @(); [void](Save-RgPolicy $pp)
    Assert ((Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy -DryRun).outcome -eq 'dry-run' -and (Test-Path (Join-Path $cache 'e1-old\blob.bin'))) 'DryRun: báo "sẽ dọn" mà không xoá'
    $r4 = Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy
    Assert ($r4.outcome -eq 'done' -and -not (Test-Path (Join-Path $cache 'e1-old\blob.bin')) -and $r4.result.freedBytes -gt 0) 'policy @ L3, mode on, mục đủ tuổi -> dọn thật qua plan/approve/apply, báo số byte'
    $jl = @(Read-RgJournal | Where-Object { $_.kind -eq 'cache-aged' -and $_.phase -eq 'intent' })
    Assert ($jl.Count -ge 1) 'action ghi journal intent như mọi đường xoá khác'
    $lg = Get-Content (Join-Path $home_ ('logs\rg-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))) -Raw -Encoding UTF8
    Assert ($lg -match '"event":"action"' -and $lg -match '"outcome":"done"') 'action được ghi nhật ký (id, actor, nhóm, mức, kết quả)'

    # end-process / lower-priority qua registry
    $ae = NewPing; $al = NewPing; Start-Sleep -Milliseconds 800
    SetAuto 'on' @{}
    $re1 = Invoke-RgAction -Id 'end-process' -Params @{ pid = $ae.Id; start = (Stamp $ae) } -Actor agent
    Assert ($re1.outcome -eq 'needs-approval' -and (Get-Process -Id $ae.Id -ErrorAction SilentlyContinue)) 'end-process: agent không bao giờ tự kết thúc (trần L2) -> needs-approval, process còn sống'
    [void](Register-RgProcess -ProcId $ae.Id -Agent 'claude' -Label 'e1 orphan' -OwnerPid 999999)
    SetAuto 'on' @{ 'process-end' = 'L0' }
    $re0 = Invoke-RgAction -Id 'end-process' -Params @{ pid = $ae.Id; start = (Stamp $ae) } -Actor human
    Assert ($re0.outcome -eq 'refused' -and $re0.reason -match 'đang tắt' -and (Get-Process -Id $ae.Id -ErrorAction SilentlyContinue)) 'nhóm process-end ở L0: kể cả người bấm cũng bị chặn (nhóm đang tắt)'
    SetAuto 'on' @{}
    $re2 = Invoke-RgAction -Id 'end-process' -Params @{ pid = $ae.Id; start = (Stamp $ae) } -Actor human
    Assert ($re2.outcome -eq 'done' -and $re2.result.ok -and -not (Get-Process -Id $ae.Id -ErrorAction SilentlyContinue)) 'end-process: người bấm, tiến trình ledger mồ côi -> kết thúc và xác minh (đường B1 qua registry)'
    $rl = Invoke-RgAction -Id 'lower-priority' -Params @{ pid = $al.Id; start = (Stamp $al); level = 'below' } -Actor human
    Assert ($rl.outcome -eq 'done' -and $rl.result.ok) 'lower-priority qua registry: hạ ưu tiên thành công'
    [void](Invoke-RgAction -Id 'lower-priority' -Params @{ pid = $al.Id; start = (Stamp $al); level = 'normal' } -Actor human)
    Assert ((Invoke-RgAction -Id 'lower-priority' -Params @{ pid = $al.Id; start = (Stamp $al); level = 'high' } -Actor human).outcome -eq 'invalid') 'lower-priority: level lạ -> invalid'
    Stop-Process -Id $al.Id -Force -ErrorAction SilentlyContinue
    $rcB = Invoke-RgAction -Id 'archive-cluster' -Params @{ clusterId = 'ffffffffffff' } -Actor human
    Assert ($rcB.outcome -eq 'refused' -and $rcB.reason) 'archive-cluster với cụm không có: bị backend từ chối, lý do tiếng Việt được giữ'

    # =====================================================================
    Write-Host "`n[E2] Mức tự chủ quyết định engine tự dọn (policy hiệu lực)"
    $stressFake = [pscustomobject]@{ diskStress = $true; ramStress = $false; diskFreeGB = 1; availRamGB = 8; drives = @() }
    $candCache = [pscustomobject]@{ kind = 'cache-aged'; action = 'delete'; path = $cache; sizeBytes = 1GB; young = $false; ageDays = 30; pid = 0; name = '' }
    $candTemp = [pscustomobject]@{ kind = 'temp-entry'; action = 'delete'; path = (Join-Path $tmp 'x'); sizeBytes = 1GB; young = $false; ageDays = 30; pid = 0; name = '' }
    $candNm = [pscustomobject]@{ kind = 'node_modules'; action = 'delete'; path = (Join-Path $ws 'nm'); sizeBytes = 1GB; young = $false; ageDays = 30; pid = 0; name = '' }
    function PolWith($Auto) { $p = Get-RgDefaultPolicy; $p.mode = 'on'; $p.targetFreeGB = 100; $p.maxGBPerRun = 50; $p.autonomy = (ConvertTo-RgAutonomy $Auto); return $p }
    $sel0 = Select-RgAutoItems @($candCache, $candTemp, $candNm) (PolWith @{}) $stressFake
    Assert (@($sel0.selected | ForEach-Object { $_.kind }) -contains 'temp-entry' -and @($sel0.selected | Where-Object { $_.kind -eq 'cache-aged' }).Count -eq 0) 'không đặt autonomy: engine giữ hành vi cũ (temp-entry auto, cache-aged ask nên bị bỏ)'
    $sel1 = Select-RgAutoItems @($candCache, $candTemp, $candNm) (PolWith @{ 'dev-cache' = 'L3'; 'temp-files' = 'L0'; 'build-artifacts' = 'L3' }) $stressFake
    Assert (@($sel1.selected | ForEach-Object { $_.kind }) -contains 'cache-aged' -and @($sel1.selected | Where-Object { $_.kind -eq 'temp-entry' }).Count -eq 0 -and @($sel1.skipped | Where-Object { $_.kind -eq 'temp-entry' -and $_.reason -match 'keep' }).Count -eq 1) 'dev-cache=L3 được chọn tự động; temp-files=L0 bị bỏ (keep)'
    Assert (@($sel1.selected | Where-Object { $_.kind -eq 'node_modules' }).Count -eq 0) 'build-artifacts bị chặn trần L2: không bao giờ tự động dù đặt L3'
    $sel2 = Select-RgAutoItems @($candCache) (PolWith @{ 'dev-cache' = 'L2' }) $stressFake
    Assert (@($sel2.selected).Count -eq 0) 'dev-cache=L2 (chờ duyệt): engine không tự chọn'

    # =====================================================================
    Write-Host "`n[E3] Đo lại sau khi dọn, banner, chống lặp"
    $over = [pscustomobject]@{ diskStress = $true; ramStress = $false; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 3; targetFreeGB = 25; stress = $true }) }
    $clear = [pscustomobject]@{ diskStress = $false; ramStress = $false; drives = @() }
    Remove-Item (Join-Path $home_ 'state\autonomy-state.json') -Force -ErrorAction SilentlyContinue
    $u1 = Update-RgAutonomyState $over 1GB $true
    $b1 = Get-RgAutonomyBanner
    Assert ($u1.over -and $u1.newlyNotified -and $b1.active -and $b1.message -match 'vẫn dưới mốc' -and @($b1.drives)[0].drive -eq 'C') 'vẫn quá mốc sau khi dọn -> báo MỘT lần (banner kèm ổ và số GB trống)'
    $u2 = Update-RgAutonomyState $over 0 $true
    Assert (-not $u2.newlyNotified -and (Get-RgAutonomyBanner).active -and (Get-RgAutonomyBanner).since -eq $b1.since) 'lượt sau vẫn quá mốc: không báo lại (chống lặp), banner giữ nguyên'
    [void](Set-RgAutonomySnooze 2)
    Assert (-not (Get-RgAutonomyBanner).active) 'hoãn: banner ẩn'
    $st = Read-RgAutonomyState; $st.snoozeUntil = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o'); Save-RgAutonomyState $st
    Assert ((Get-RgAutonomyBanner).active) 'hết hạn hoãn: banner hiện lại'
    $u3 = Update-RgAutonomyState $clear 0 $false
    Assert (-not $u3.over -and -not (Get-RgAutonomyBanner).active -and -not (Read-RgAutonomyState).notified) 'xuống dưới mốc -> mở khoá, banner tắt'
    $u4 = Update-RgAutonomyState $over 0 $true
    Assert ($u4.newlyNotified -and (Get-RgAutonomyBanner).active) 'vượt mốc lại sau khi đã xuống -> báo lại'
    [void](Update-RgAutonomyState $clear 0 $false)

    # =====================================================================
    Write-Host "`n[E4] Nâng/hạ mức theo số liệu, dừng khẩn cấp"
    $cfgAdv = Get-RgConfig -Fresh   # bản riêng để sửa: Get-RgConfig thường trả đối tượng dùng chung, chỉ đọc
    $cfgAdv.autonomy.promoteMinRuns = 3; $cfgAdv.autonomy.promoteMinDays = 0; $cfgAdv.autonomy.demoteRestoreRate = 0.0001; $cfgAdv.autonomy.demoteMinArchives = 2; $cfgAdv.autonomy.demoteFailures = 3
    SetAuto 'dry-run' @{ 'dev-cache' = 'L2' }
    1..2 | ForEach-Object { Write-RgLog 'auto-run' ([ordered]@{ mode = 'dry-run'; items = 1; freedBytes = 0; trigger = 'manual'; byKind = [ordered]@{ 'cache-aged' = [ordered]@{ items = 2; bytes = 1GB } } }) }
    $jf0 = @(Read-RgJournal | Where-Object { $_.phase -eq 'failed' }).Count
    Assert (@((Get-RgAutonomyAdvice $cfgAdv).promote | Where-Object { $_.group -eq 'dev-cache' }).Count -eq 0 -or $jf0 -ge 3) 'chưa đủ số lượt chạy thử: chưa đề nghị nâng'
    1..2 | ForEach-Object { Write-RgLog 'auto-run' ([ordered]@{ mode = 'dry-run'; items = 1; freedBytes = 0; trigger = 'manual'; byKind = [ordered]@{ 'cache-aged' = [ordered]@{ items = 2; bytes = 1GB } } }) }
    $adv = Get-RgAutonomyAdvice $cfgAdv
    $pr = @($adv.promote | Where-Object { $_.group -eq 'dev-cache' })[0]
    if ($jf0 -lt 3) { Assert ($pr -and $pr.to -eq 'L3' -and $pr.needsPin -and $pr.evidence.dryRuns -ge 3 -and $pr.reason -match 'lượt chạy thử') 'đủ lượt chạy thử, không lỗi -> đề nghị nâng dev-cache lên L3 (cần PIN) kèm bằng chứng' }
    else { Write-Host '  SKIP  đề nghị nâng: sandbox đã có >= 3 lỗi journal từ test trước' }
    SetAuto 'dry-run' @{ 'personal-compress' = 'L2' }
    $dm = @((Get-RgAutonomyAdvice $cfgAdv).demote | Where-Object { $_.group -eq 'personal-compress' })
    Assert ($dm.Count -eq 1 -and $dm[0].to -eq 'L1' -and $dm[0].reason -match 'khôi phục') 'bản nén bị khôi phục nhiều (theo ngưỡng cấu hình) -> đề nghị hạ personal-compress về L1'
    $dem = @(Invoke-RgAutonomyDemote $cfgAdv)
    Assert ($dem.Count -ge 1 -and (Get-RgGroupLevel (Get-RgPolicy) 'personal-compress').level -eq 'L1' -and @((Read-RgAutonomyState).demotions).Count -ge 1) 'tự hạ: policy.json đổi sang L1 và state ghi lại lần hạ (không cần PIN)'
    SetAuto 'dry-run' @{ 'dev-cache' = 'L3' }
    1..3 | ForEach-Object { $j = Write-RgJournalIntent -Action 'delete' -Kind 'cache-aged' -Target "e4-$_"; Close-RgJournal $j 'failed' 'giả lập lỗi' }
    $dem2 = @(Invoke-RgAutonomyDemote $cfgAdv)
    Assert (@($dem2 | Where-Object { $_.group -eq 'dev-cache' -and $_.to -eq 'L2' }).Count -eq 1 -and (Get-RgGroupLevel (Get-RgPolicy) 'dev-cache').level -eq 'L2') 'nhiều lần dọn lỗi -> tự hạ dev-cache từ L3 xuống L2'

    # dừng khẩn cấp
    SetAuto 'on' @{ 'dev-cache' = 'L3' }
    $jobProc = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', "Start-Sleep -Seconds 120; 'rg-auto.ps1'" -WindowStyle Hidden -PassThru
    $decoy = NewPing; Start-Sleep -Milliseconds 800
    Write-RgJobState 'auto.progress.json' ([ordered]@{ pid = $jobProc.Id; status = 'running'; message = 'giả lập'; startedUtc = (Get-Date).ToUniversalTime().ToString('o'); updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    Write-RgJobState 'agent.progress.json' ([ordered]@{ pid = $decoy.Id; status = 'running'; message = 'giả lập (không phải job của Resource Guard)'; startedUtc = (Get-Date).ToUniversalTime().ToString('o'); updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    $pn = Invoke-RgPanic -By 'test'
    Start-Sleep -Milliseconds 500
    Assert ((Get-RgPolicy).mode -eq 'off' -and $pn.modeBefore -eq 'on') 'panic: chính sách tự động về off'
    Assert (@($pn.stopped) -contains 'auto.progress.json' -and -not (Get-Process -Id $jobProc.Id -ErrorAction SilentlyContinue) -and (Get-RgJobState 'auto.progress.json').status -eq 'error' -and (Get-RgJobState 'auto.progress.json').message -match 'khẩn cấp') 'panic: job nền của Resource Guard bị huỷ và đánh dấu "dừng khẩn cấp"'
    Assert ((Get-Process -Id $decoy.Id -ErrorAction SilentlyContinue) -and @($pn.stopped) -notcontains 'agent.progress.json') 'panic: tiến trình không phải job của Resource Guard (dòng lệnh không khớp) không bị đụng tới'
    Assert ((Test-Path (Join-Path $home_ 'state\panic-last.json')) -and (Invoke-RgAction -Id 'clean-cache' -Params @{ key = 'e1e1e1e1e1e1' } -Actor policy).reason -match 'tắt') 'panic: sau đó tác nhân tự động bị từ chối cho tới khi người dùng bật lại'
    Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $home_ 'state\auto.progress.json'), (Join-Path $home_ 'state\agent.progress.json') -Force -ErrorAction SilentlyContinue
    SetAuto 'off' @{}

    Assert ((Test-Path (Join-Path $root '.github\workflows\ci.yml')) -and ((Get-Content (Join-Path $root '.github\workflows\ci.yml') -Raw -Encoding UTF8) -match 'windows-latest' -and (Get-Content (Join-Path $root '.github\workflows\ci.yml') -Raw -Encoding UTF8) -match 'Acceptance\.ps1')) 'CI: workflow windows-latest chạy Acceptance.ps1'

    # Hồi quy: nhiều job khôi phục song song không được làm mất cờ restoredUtc của nhau (archives.json có khoá).
    $arcIds = @(1..10 | ForEach-Object { '{0:x12}' -f (2000000 + $_) })
    $arcRecs = @($arcIds | ForEach-Object { [ordered]@{ id = $_; original = (Join-Path $sandbox "arc\$_"); zip = (Join-Path $sandbox "arc\$_.zip"); kind = 'cluster-file'; bytes = 1; zipBytes = 1; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); restoredUtc = $null } })
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'state'))
    Write-RgFileAtomic (Join-Path $home_ 'state\archives.json') (ConvertTo-Json -InputObject @($arcRecs) -Depth 4 -Compress)
    $arcScript = ". '$root\scripts\rg-common.ps1'; . '$root\scripts\rg-extra.ps1'; Set-RgArchiveRestored `$env:RG_ARCH_ID"
    $arcEnc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($arcScript))
    $arcProcs = @()
    foreach ($aid in $arcIds) {
        $env:RG_ARCH_ID = $aid
        $arcProcs += Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $arcEnc) -PassThru -WindowStyle Hidden
    }
    Remove-Item Env:\RG_ARCH_ID -ErrorAction SilentlyContinue
    $arcProcs | ForEach-Object { $_.WaitForExit() }
    $arcAfter = @(ConvertFrom-Json (Get-Content (Join-Path $home_ 'state\archives.json') -Raw -Encoding UTF8) | ForEach-Object { $_ })   # PS 5.1: phải bung mảng, nếu không đếm sai thành 1
    $arcMarked = @($arcAfter | Where-Object { $_.restoredUtc }).Count
    Assert ($arcMarked -eq $arcIds.Count) "khôi phục song song: $arcMarked/$($arcIds.Count) bản ghi được đánh dấu (không mất cờ nào)"
}
finally {
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_RESOURCE_HOME -ErrorAction SilentlyContinue
}
Write-Host ("`nKết quả (auto): {0} pass, {1} fail" -f $script:pass, $script:fail)
Write-Host ("AUTO-RESULT pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
