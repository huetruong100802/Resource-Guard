# Test nghiệm thu Resource Guard. Không cần Pester. Chạy: pwsh -NoProfile -File tests\Acceptance.ps1
# Mọi thao tác nằm trong thư mục tạm riêng (AGENT_RESOURCE_HOME + fixture); không đụng dữ liệu thật.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("rg-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ws = Join-Path $sandbox 'ws'; $tmp = Join-Path $sandbox 'tmp'; $cache = Join-Path $sandbox 'cache'; $home_ = Join-Path $sandbox 'home'
foreach ($d in $ws, $tmp, $cache, $home_) { [void](New-Item -ItemType Directory -Force -Path $d) }
$env:AGENT_RESOURCE_HOME = $home_

$script:pass = 0; $script:fail = 0
function Assert($Cond, [string]$Name) {
    if ([bool]$Cond) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Age([string]$Path, [int]$Days) {   # đặt mtime lùi $Days ngày cho file/dir (đệ quy)
    $t = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object {
        # file chỉ đọc (vd. object trong .git) không cho đặt mtime: bỏ cờ tạm thời rồi trả lại
        $ro = ($_ -is [IO.FileInfo]) -and $_.IsReadOnly
        if ($ro) { $_.IsReadOnly = $false }
        $_.LastWriteTime = $t; $_.LastAccessTime = $t
        if ($ro) { $_.IsReadOnly = $true }
    }
    $self = Get-Item -LiteralPath $Path -Force; $self.LastWriteTime = $t; $self.LastAccessTime = $t
}
function NewFile([string]$Path, [int]$Bytes) {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
}
function FindItem($Plan, [string]$Path) { @($Plan.items | Where-Object { $_.path -eq $Path }) | Select-Object -First 1 }
function Row($ProcId, $Par, $Name, $Cmd, $Grp) { [pscustomobject]@{ Pid = $ProcId; ParentPid = $Par; Name = $Name; Start = '20260101T000000Z'; RamMB = 100; Group = $Grp; Cmd = $Cmd } }
function Snap($ram, $disk, $commit) { [pscustomobject]@{ availRamGB = $ram; diskFreeGB = $disk; commitPct = $commit; diskDrive = 'C' } }

# cấu hình test
$cfg = Get-Content (Join-Path $root 'config.default.json') -Raw | ConvertFrom-Json
$cfg.groups.dev = @('ping')
$cfg.scan.autoRefreshHours = 0   # server chạy trong test KHÔNG được tự quét ổ thật
$cfg.cleanup.workspaceRoots = @($ws)
$cfg.cleanup.tempRoot = $tmp
$cfg.cleanup.minCacheMB = 0
$cfg.cleanup.cacheDirs = [pscustomobject]@{ 'fake-cache' = $cache }
$cfg.cleanup.vhdxGlobs = @()
$dl = Join-Path $sandbox 'dl'; $apps = Join-Path $sandbox 'apps'
foreach ($d in $dl, $apps) { [void](New-Item -ItemType Directory -Force -Path $d) }
$cfg.cleanup.staleRepo = [pscustomobject]@{ minInactiveDays = 90; minMB = 0 }
$cfg.cleanup.largeItem = [pscustomobject]@{ roots = @($dl); minMB = 0; minInactiveDays = 60 }
$cfg.cleanup.apps = [pscustomobject]@{ roots = @($apps); minMB = 0; minInactiveDays = 180; exclude = @('Windows*') }
Set-Content (Join-Path $home_ 'config.json') (ConvertTo-Json $cfg -Depth 8) -Encoding UTF8

. (Join-Path $root 'scripts\rg-common.ps1')
$procs = @()
$lockStream = $null
try {
    Write-Host "`n[1] RAM thấp -> cảnh báo/chặn trước tác vụ nặng"
    $t = @(Row 1 0 'explorer' '' 'other')
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 50 40) -Table $t).decision -eq 'allow') 'RAM 9GB -> allow'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 4 50 40) -Table $t).decision -eq 'warn') 'RAM 4GB (Caution) -> warn'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 1.5 50 40) -Table $t).decision -eq 'deny') 'RAM 1.5GB (Critical) -> deny build'
    Assert ((Get-RgBudget -Task subagent -Snapshot (Snap 2.6 50 40) -Table $t).decision -eq 'deny') 'Restricted -> không spawn subagent'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 5 40) -Table $t).decision -eq 'deny') 'Disk 5GB (Critical) -> deny build'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 50 98) -Table $t).decision -eq 'deny') 'Commit 98% -> deny build'
    Assert ((Get-RgBudget -Task test -Snapshot (Snap 5.5 50 40) -Table $t).state -ne 'Normal') 'RAM dự kiến sau test kéo state xuống'

    Write-Host "`n[2] Hai agent cùng build -> không vượt concurrency budget"
    $one = @((Row 10 1 'dotnet' 'dotnet build a.sln' 'build'))
    $two = $one + (Row 11 1 'dotnet' 'dotnet test b.sln' 'test')
    $tree = @((Row 20 1 'dotnet' 'dotnet build a.sln' 'build'), (Row 21 20 'msbuild' 'MSBuild.exe' 'build'), (Row 22 20 'dotnet' 'dotnet MSBuild.dll /nodemode:1' 'build'))
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 50 40) -Table $one).decision -eq 'allow') 'Normal: 1 build đang chạy -> build thứ 2 được phép (max 2)'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 50 40) -Table $two).decision -eq 'deny') 'Normal: 2 build đang chạy -> chặn build thứ 3'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 9 50 40) -Table $tree).heavyRunning -eq 1) '1 build + worker MSBuild chỉ tính 1 slot'
    Assert ((Get-RgBudget -Task build -Snapshot (Snap 2.8 50 40) -Table $one).decision -eq 'deny') 'Restricted: không chạy song song'

    Write-Host "`n[3] Agent kết thúc -> phát hiện child còn sót (ledger theo PID+start time)"
    $owner = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $owner
    $child = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $child
    $stranger = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $stranger   # process của "người dùng", không đăng ký
    Start-Sleep -Milliseconds 800
    [void](Register-RgProcess -ProcId $child.Id -Agent 'claude' -Label 'test child' -OwnerPid $owner.Id)
    Assert (@(Get-RgLedgerOrphans).Count -eq 0) 'owner còn sống -> chưa orphan'
    Stop-Process -Id $owner.Id -Force; Start-Sleep -Milliseconds 800
    $orph = @(Get-RgLedgerOrphans)
    Assert ($orph.Count -eq 1 -and $orph[0].pid -eq $child.Id) 'owner chết -> child được báo orphan'

    Write-Host "`n[4/5] Disk hotspot + cache lớn -> plan có số liệu"
    NewFile (Join-Path $ws 'proj\proj.csproj') 10
    NewFile (Join-Path $ws 'proj\bin\Debug\a.dll') 2MB;  Age (Join-Path $ws 'proj\bin') 30
    NewFile (Join-Path $ws 'fresh\fresh.csproj') 10
    NewFile (Join-Path $ws 'fresh\obj\b.dll') 1MB                                  # mới => KHÔNG được đề xuất
    NewFile (Join-Path $ws 'web\package.json') 10
    NewFile (Join-Path $ws 'web\node_modules\x\i.js') 3MB; Age (Join-Path $ws 'web\node_modules') 60
    NewFile (Join-Path $ws 'locked\locked.csproj') 10
    NewFile (Join-Path $ws 'locked\obj\held.bin') 1MB;   Age (Join-Path $ws 'locked\obj') 30
    NewFile (Join-Path $ws 'gitrepo\.git\obj\x.bin') 1MB                           # trong .git => không bao giờ
    NewFile (Join-Path $tmp 'old.tmp') 500KB; Age (Join-Path $tmp 'old.tmp') 20
    NewFile (Join-Path $tmp 'new.tmp') 500KB
    NewFile (Join-Path $cache 'pkg\old.nupkg') 4MB; Age (Join-Path $cache 'pkg\old.nupkg') 30
    NewFile (Join-Path $cache 'pkg\fresh.nupkg') 1MB                               # mới => phải được giữ
    NewFile (Join-Path $cache 'empty-after\gone.bin') 100KB; Age (Join-Path $cache 'empty-after') 30

    $plan = New-RgPlan -Items @(Get-RgCandidates)
    $binItem = FindItem $plan (Join-Path $ws 'proj\bin')
    $nmItem = FindItem $plan (Join-Path $ws 'web\node_modules')
    $cacheItem = FindItem $plan $cache
    $lockedItem = FindItem $plan (Join-Path $ws 'locked\obj')
    $oldTmp = FindItem $plan (Join-Path $tmp 'old.tmp')
    $killItem = @($plan.items | Where-Object { $_.kind -eq 'process' -and $_.action -eq 'kill' }) | Select-Object -First 1
    Assert ($binItem -and $binItem.sizeBytes -ge 2MB -and $binItem.level -eq 1) 'bin cũ: có path tuyệt đối + dung lượng thật + level 1'
    Assert ($nmItem -and $nmItem.level -eq 2 -and $nmItem.sizeBytes -ge 3MB) 'node_modules cũ: level 2 (cần duyệt)'
    Assert ($cacheItem -and $cacheItem.kind -eq 'cache-aged' -and $cacheItem.sizeBytes -ge 4MB -and $cacheItem.sizeBytes -lt 4.3MB -and $cacheItem.ageDays -eq 14 -and $cacheItem.reason -and $cacheItem.risk) 'cache: chỉ tính file không hoạt động >= 14 ngày, có số liệu + lý do + rủi ro'
    Assert ($oldTmp -and -not (FindItem $plan (Join-Path $tmp 'new.tmp'))) 'temp: chỉ đề xuất file đủ tuổi'
    Assert (-not (FindItem $plan (Join-Path $ws 'fresh\obj'))) 'obj mới sửa gần đây không bị đề xuất'
    Assert (-not (@($plan.items | Where-Object { $_.path -like '*\.git\*' }).Count)) 'không đề xuất gì trong .git'
    Assert ($killItem -and $killItem.pid -eq $child.Id -and $killItem.start) 'process orphan của agent: có PID + start time'
    Assert (-not (@($plan.items | Where-Object { $_.pid -eq $stranger.Id -and $_.action -eq 'kill' }).Count)) 'process người dùng không đăng ký: không bao giờ ở dạng kill'
    Assert ($plan.itemsHash -and $plan.planId -match '^[0-9a-f]{12}$' -and $plan.approval.status -eq 'pending') 'plan có id/hash/approval=pending'

    Write-Host "`n[6] User chưa duyệt -> không xoá, không kill"
    $r = Invoke-RgApply -PlanId $plan.planId
    Assert ($r.code -eq 4 -and -not $r.ok) 'apply bị từ chối (code 4)'
    Assert ((Test-Path (Join-Path $ws 'proj\bin')) -and (Test-Path (Join-Path $ws 'web\node_modules')) -and (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) 'dữ liệu và process còn nguyên'
    $threw = $false; try { Approve-RgPlan -PlanId $plan.planId -All | Out-Null } catch { $threw = $true }
    Assert $threw 'Approve-RgPlan từ chối khi stdin bị redirect/không tương tác'
    $threw = $false; try { Set-RgPlanApproval -PlanId $plan.planId -ItemIds @(999) | Out-Null } catch { $threw = $true }
    Assert $threw 'không duyệt được item không tồn tại'

    Write-Host "`n[7/8] Duyệt -> revalidate; lỗi được ghi log; PID đổi không kill nhầm"
    [void](Set-RgPlanApproval -PlanId $plan.planId -ItemIds @($binItem.id, $nmItem.id, $lockedItem.id, $killItem.id, $cacheItem.id) -By 'test-human')
    $lockStream = [IO.File]::Open((Join-Path $ws 'locked\obj\held.bin'), 'Open', 'ReadWrite', 'None')   # khoá file => xoá phải fail
    $dry = Invoke-RgApply -PlanId $plan.planId -DryRun
    Assert ($dry.message -eq 'dry run' -and (Test-Path (Join-Path $ws 'proj\bin'))) 'dry run không thay đổi gì'
    $r = Invoke-RgApply -PlanId $plan.planId
    $byId = @{}; foreach ($x in $r.results) { $byId[[int]$x.id] = $x }
    Assert ($byId[[int]$binItem.id].outcome -eq 'done' -and -not (Test-Path (Join-Path $ws 'proj\bin'))) 'bin đã duyệt: đã xoá'
    Assert ($byId[[int]$nmItem.id].outcome -eq 'done' -and -not (Test-Path (Join-Path $ws 'web\node_modules'))) 'node_modules đã duyệt: đã xoá'
    Assert ($byId[[int]$killItem.id].outcome -eq 'done' -and -not (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) 'orphan của agent: đã kill'
    Assert ($byId[[int]$lockedItem.id].outcome -eq 'failed' -and $byId[[int]$lockedItem.id].detail) 'cleanup thất bại: báo nguyên nhân'
    Assert ((Test-Path (Join-Path $ws 'locked\obj\held.bin'))) 'file bị khoá còn nguyên'
    Assert ((Test-Path (Join-Path $tmp 'old.tmp'))) 'item không được duyệt (temp) còn nguyên'
    Assert ($byId[[int]$cacheItem.id].outcome -eq 'done' -and -not (Test-Path (Join-Path $cache 'pkg\old.nupkg')) -and -not (Test-Path (Join-Path $cache 'empty-after'))) 'cache: file cũ đã xoá, thư mục rỗng được dọn'
    Assert ((Test-Path (Join-Path $cache 'pkg\fresh.nupkg')) -and (Test-Path $cache)) 'cache: file mới (< 14 ngày) và thư mục gốc còn nguyên'
    Assert ((Get-Process -Id $stranger.Id -ErrorAction SilentlyContinue)) 'process người dùng còn sống'
    $logText = (Get-ChildItem (Join-Path $home_ 'logs') -Filter '*.jsonl' | Get-Content -Raw) -join ''
    Assert ($logText -match 'apply-item' -and $logText -match '"outcome":"failed"') 'log ghi lại thao tác và lỗi'
    Assert ((Invoke-RgApply -PlanId $plan.planId).code -eq 6) 'apply lần 2 bị từ chối (đã applied)'
    $lockStream.Dispose(); $lockStream = $null

    Write-Host "`n[PID đổi] Start time không khớp -> không kill"
    $victim = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $victim
    Start-Sleep -Milliseconds 800
    $reg = Register-RgProcess -ProcId $victim.Id -Agent 'codex' -Label 'victim' -OwnerPid 999999
    $badItem = New-RgItem -Kind 'process' -Action 'kill' -Level 1 -ProcId $victim.Id -Start '20200101T000000Z' -Name 'ping' -Reason 'pid reuse simulation'
    $good = New-RgItem -Kind 'process' -Action 'kill' -Level 1 -ProcId $victim.Id -Start $reg.start -Name 'ping' -Reason 'control'
    $p2 = New-RgPlan -Items @($badItem)
    [void](Set-RgPlanApproval -PlanId $p2.planId -ItemIds @(1) -By 'test-human')
    $r2 = Invoke-RgApply -PlanId $p2.planId
    Assert ($r2.results[0].outcome -eq 'skipped' -and $r2.results[0].detail -match 'reused' -and (Get-Process -Id $victim.Id -ErrorAction SilentlyContinue)) 'PID trùng nhưng start time khác: bỏ qua, process còn sống'

    Write-Host "`n[Bảo vệ] Allowlist, junction, .git, plan bị sửa"
    $lowFloor = New-RgPlan -Items @((New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -AgeDays 1 -Reason 'floor test'))
    [void](Set-RgPlanApproval -PlanId $lowFloor.planId -ItemIds @(1) -By 'test-human')
    Assert ((Invoke-RgApply -PlanId $lowFloor.planId).results[0].detail -match 'policy floor') 'ageDays thấp hơn sàn chính sách (14): bị chặn'

    Write-Host "`n[Young] Mục dưới sàn tuổi: người duyệt được xoá, auto-clean thì không"
    $youngItem = { New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -AgeDays 0 -Young $true -Reason 'young test' }
    $yHuman = New-RgPlan -Items @(& $youngItem)
    [void](Set-RgPlanApproval -PlanId $yHuman.planId -ItemIds @(1) -By 'test-human')
    Assert ((Invoke-RgApply -PlanId $yHuman.planId -DryRun).results[0].outcome -eq 'would-run') 'young + người duyệt: bỏ sàn tuổi, được phép chạy'
    $yAuto = New-RgPlan -Items @(& $youngItem)
    [void](Set-RgPlanApproval -PlanId $yAuto.planId -ItemIds @(1) -By 'policy')
    $yr = Invoke-RgApply -PlanId $yAuto.planId -DryRun
    Assert ($yr.results[0].outcome -eq 'skipped' -and $yr.results[0].detail -match 'human approval') 'young + plan do policy tự duyệt: bị chặn'
    Assert ((Get-RgItemsHash @((& $youngItem))) -ne (Get-RgItemsHash @((New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -AgeDays 0 -Reason 'young test')))) 'cờ young nằm trong hash của plan (không sửa được sau khi duyệt)'

    $outside = Join-Path $sandbox 'outside'; NewFile (Join-Path $outside 'x\bin\f.dll') 1KB; NewFile (Join-Path $outside 'x\x.csproj') 1
    Age (Join-Path $outside 'x\bin') 30
    $junc = Join-Path $ws 'proj\obj'; NewFile (Join-Path $outside 'real\k.txt') 1KB
    [void](New-Item -ItemType Junction -Path $junc -Target (Join-Path $outside 'real'))
    NewFile (Join-Path $ws 'proj\proj2.csproj') 1
    $evil = @(
        (New-RgItem -Kind 'dotnet-artifact' -Action 'delete' -Level 1 -Path (Join-Path $outside 'x\bin') -Reason 'outside roots'),
        (New-RgItem -Kind 'dotnet-artifact' -Action 'delete' -Level 1 -Path $junc -Reason 'junction'),
        (New-RgItem -Kind 'dotnet-artifact' -Action 'delete' -Level 1 -Path (Join-Path $ws 'gitrepo\.git\obj') -Reason 'inside .git'),
        (New-RgItem -Kind 'dotnet-artifact' -Action 'delete' -Level 1 -Path (Join-Path $ws 'proj') -Reason 'not bin/obj'),
        (New-RgItem -Kind 'unknown-kind' -Action 'delete' -Level 1 -Path (Join-Path $outside 'real') -Reason 'bad kind')
    )
    $p3 = New-RgPlan -Items $evil
    [void](Set-RgPlanApproval -PlanId $p3.planId -ItemIds @(1, 2, 3, 4, 5) -By 'test-human')
    $r3 = Invoke-RgApply -PlanId $p3.planId
    Assert (@($r3.results | Where-Object { $_.outcome -eq 'skipped' }).Count -eq 5) 'cả 5 item nguy hiểm đều bị chặn lúc apply dù đã duyệt'
    Assert ((Test-Path (Join-Path $outside 'x\bin\f.dll')) -and (Test-Path (Join-Path $outside 'real\k.txt')) -and (Test-Path (Join-Path $ws 'gitrepo\.git\obj\x.bin'))) 'dữ liệu ngoài root / sau junction / trong .git còn nguyên'

    $p4 = New-RgPlan -Items @((New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path (Join-Path $tmp 'old.tmp') -SizeBytes 1 -Reason 'tamper test'))
    [void](Set-RgPlanApproval -PlanId $p4.planId -ItemIds @(1) -By 'test-human')
    $pf = Join-Path $home_ "plans\$($p4.planId).json"
    (Get-Content $pf -Raw).Replace('old.tmp', 'new.tmp') | Set-Content $pf -Encoding UTF8   # đổi đích sau khi duyệt
    $r4 = Invoke-RgApply -PlanId $p4.planId
    Assert ($r4.code -eq 5 -and (Test-Path (Join-Path $tmp 'new.tmp'))) 'plan bị sửa sau khi duyệt: từ chối (code 5)'

    # ---- watcher (chỉ giám sát) ----
    . (Join-Path $root 'scripts\rg-watcher.ps1')
    $e = Get-RgEffectiveState 'Normal' 0 'Critical'
    Assert ($e.state -eq 'Critical') 'watcher: tăng trạng thái áp dụng ngay'
    $e = Get-RgEffectiveState 'Critical' 0 'Normal'
    Assert ($e.state -eq 'Critical' -and $e.lowerCount -eq 1) 'watcher: hạ trạng thái chưa áp dụng ở lần đầu (hysteresis)'
    $e = Get-RgEffectiveState 'Critical' 2 'Normal'
    Assert ($e.state -eq 'Normal') 'watcher: hạ sau đủ chu kỳ liên tiếp'
    $e = Get-RgEffectiveState 'Caution' 2 'Caution'
    Assert ($e.state -eq 'Caution' -and $e.lowerCount -eq 0) 'watcher: bằng trạng thái hiện tại thì reset bộ đếm'
    Assert ((Get-RgSettings).intervalSec -eq 15) 'settings: mặc định lấy mẫu 15 giây'
    Assert ((Set-RgSettings 30).intervalSec -eq 30 -and (Get-RgSettings).intervalSec -eq 30) 'settings: lưu và đọc lại chu kỳ'
    $bad = 0; foreach ($v in 1, 301, -5) { try { [void](Set-RgSettings $v) } catch { $bad++ } }
    Assert ($bad -eq 3 -and (Get-RgSettings).intervalSec -eq 30) 'settings: giá trị ngoài 2-300 bị từ chối, không đổi cài đặt'
    $e = Get-RgEffectiveState 'Critical' 0 'Normal' 2
    Assert ($e.state -eq 'Critical' -and (Get-RgEffectiveState 'Critical' 1 'Normal' 2).state -eq 'Normal') 'watcher: số chu kỳ giữ trạng thái cấu hình được'
    $freeBefore = (Get-ChildItem -LiteralPath $tmp -Force | Measure-Object).Count
    $rec = Invoke-RgWatchTick -NoToast
    Assert ((Test-Path (Join-Path $home_ 'state\status.html')) -and (Test-Path (Join-Path $home_ 'state\watcher.json'))) 'watcher: một chu kỳ ghi status.html + watcher.json'
    Assert (@(Get-ChildItem (Join-Path $home_ 'state') -Filter 'metrics-*.jsonl').Count -eq 1) 'watcher: ghi metrics jsonl'
    Assert ((Get-ChildItem -LiteralPath $tmp -Force | Measure-Object).Count -eq $freeBefore) 'watcher: không xoá/đổi gì trong thư mục tạm (monitor-only)'

    # ---- lịch sử theo tiến trình (P2): procTop trong metrics + Get-RgProcHistory ----
    $pt = @($rec.procTop)
    Assert ($pt.Count -ge 1 -and $pt.Count -le 20 -and $pt[0].name -and $null -ne $pt[0].n -and $null -ne $pt[0].cpu -and $null -ne $pt[0].ramMB) 'procTop: bản ghi tick có nhóm theo tên {name,n,cpu,ramMB}, tối đa 12+8 nhóm'
    Assert (@($pt | Group-Object name | Where-Object Count -gt 1).Count -eq 0) 'procTop: mỗi tên chỉ một nhóm (đã gộp)'
    $mfLast = Get-Content (Get-ChildItem (Join-Path $home_ 'state') -Filter 'metrics-*.jsonl' | Sort-Object Name | Select-Object -Last 1).FullName -Tail 1 -Encoding UTF8 | ConvertFrom-Json
    Assert (@($mfLast.procTop).Count -ge 1) 'procTop: có trong dòng metrics đã ghi ra file'
    $gp = Get-RgProcTop @(
        [pscustomobject]@{ name = 'aaa'; cpu = 1.0; ramMB = 100 }, [pscustomobject]@{ name = 'aaa'; cpu = 2.5; ramMB = 50 },
        [pscustomobject]@{ name = 'bbb'; cpu = 0.0; ramMB = 10 }, [pscustomobject]@{ name = 'ccc'; cpu = 9.0; ramMB = 1 })
    $ga = @($gp | Where-Object name -eq 'aaa')[0]
    Assert ($ga.n -eq 2 -and $ga.cpu -eq 3.5 -and $ga.ramMB -eq 150 -and @($gp).Count -eq 3) 'procTop: cộng n/cpu/ramMB theo tên'
    $many = @(1..30 | ForEach-Object { [pscustomobject]@{ name = "p$_"; cpu = 0.0; ramMB = $_ } })
    Assert (@(Get-RgProcTop $many).Count -eq 12) 'procTop: chỉ giữ top 12 theo RAM (CPU = 0 không thêm nhóm)'
    # ---- danh tính tiến trình (P2 plan-ux-clarity): fixture bảng tiến trình giả, không phụ thuộc máy ----
    $idCfg = Get-RgConfig
    $idRoots = @('C:\fx\Work')
    $idRows = @{}
    function New-IdRow([int]$ProcId, [int]$ParentId, [string]$N, [string]$Start, [string]$C, [string]$Grp = 'other') { $r = [pscustomobject]@{ Pid = $ProcId; ParentPid = $ParentId; Name = $N; Start = $Start; Cmd = $C; Group = $Grp }; $idRows[$ProcId] = $r; return $r }
    [void](New-IdRow 100 1 'code' '20260101T000000Z' '"C:\Program Files\Microsoft VS Code\Code.exe"')
    [void](New-IdRow 101 100 'pwsh' '20260101T000100Z' 'pwsh.exe -NoLogo')
    $rBuild = New-IdRow 102 101 'dotnet' '20260101T000200Z' '"C:\Program Files\dotnet\dotnet.exe" build C:\fx\Work\dxwms\src\Api\Api.csproj' 'build'
    $iBuild = Get-RgProcIdentity $rBuild $idRows $idCfg @{} $idRoots
    Assert ($iBuild.role -eq 'build' -and $iBuild.project -eq 'dxwms' -and $iBuild.owner.name -eq 'code' -and $iBuild.owner.label -eq 'VS Code' -and $iBuild.confidence -eq 'rule') 'identity: dotnet build dưới Code -> pwsh: role build, dự án dxwms, owner Code'
    Assert (($iBuild.chain -join '>') -eq 'code>pwsh>dotnet' -and $iBuild.workload -eq 'build|dxwms' -and $iBuild.what -like '*dxwms*') 'identity: chain code>pwsh>dotnet, workload build|dxwms'
    $rNg = New-IdRow 103 101 'node' '20260101T000300Z' 'node "C:\fx\Work\dxwms\web\node_modules\@angular\cli\bin\ng.js" serve --port 4200' 'dev'
    $iNg = Get-RgProcIdentity $rNg $idRows $idCfg @{} $idRoots
    Assert ($iNg.role -eq 'devserver' -and $iNg.title -eq 'Angular dev server' -and $iNg.project -eq 'dxwms') 'identity: node ... ng.js serve -> devserver Angular'
    $rSvc = New-IdRow 104 1 'svchost' '20260101T000000Z' 'C:\Windows\system32\svchost.exe -k netsvcs'
    $iSvc = Get-RgProcIdentity $rSvc $idRows $idCfg @{ 104 = @('Windows Update', 'BITS') } $idRoots
    Assert ($iSvc.role -eq 'system' -and $iSvc.what -like '*2 dịch vụ*Windows Update*BITS*') 'identity: svchost liệt kê 2 dịch vụ'
    $rOrph = New-IdRow 105 9999 'dotnet' '20260101T000400Z' 'dotnet.exe test C:\fx\Work\orphanproj\T.csproj' 'build'
    $iOrph = Get-RgProcIdentity $rOrph $idRows $idCfg @{} $idRoots
    Assert ($iOrph.role -eq 'test' -and $iOrph.owner -eq $null -and $iOrph.project -eq 'orphanproj' -and @($iOrph.chain).Count -eq 1) 'identity: tiến trình mồ côi vẫn có role/dự án, không owner'
    $rNoProj = New-IdRow 106 9999 'dotnet' '20260101T000400Z' 'dotnet.exe build D:\elsewhere\X.csproj' 'build'
    $iNoProj = Get-RgProcIdentity $rNoProj $idRows $idCfg @{} $idRoots
    Assert ($iNoProj.project -eq $null -and $iNoProj.confidence -eq 'guess') 'identity: không nằm dưới workspaceRoots -> project null, confidence guess'
    $rEmpty = New-IdRow 107 9999 'mystery' '20260101T000400Z' ''
    $iEmpty = Get-RgProcIdentity $rEmpty $idRows $idCfg @{} $idRoots
    Assert ($iEmpty.role -eq 'unknown' -and $iEmpty.what -eq 'Chưa nhận diện được' -and $iEmpty.confidence -eq 'guess') 'identity: dòng lệnh rỗng (không có quyền đọc) -> unknown, không lỗi'
    # PID tái sử dụng + vòng lặp cha-con: không treo, không lấy cha khởi động sau con
    [void](New-IdRow 110 111 'a' '20260101T000500Z' 'a.exe')
    [void](New-IdRow 111 110 'b' '20260101T000500Z' 'b.exe')
    $iLoop = Get-RgProcIdentity $idRows[110] $idRows $idCfg @{} $idRoots
    Assert (@($iLoop.chain).Count -le 5 -and $iLoop.chain[-1] -eq 'a') 'identity: vòng lặp cha-con không treo'
    $rReuse = New-IdRow 112 100 'dotnet' '20250101T000000Z' 'dotnet.exe build C:\fx\Work\old\A.csproj' 'build'
    $iReuse = Get-RgProcIdentity $rReuse $idRows $idCfg @{} $idRoots
    Assert ($iReuse.owner -eq $null) 'identity: cha khởi động sau con (PID tái sử dụng) bị bỏ qua'
    $wls = @(Get-RgWorkloads @(
            [pscustomobject]@{ pid = 102; ramMB = 400; cpu = 10; protected = $false; identity = $iBuild },
            [pscustomobject]@{ pid = 103; ramMB = 900; cpu = 2; protected = $false; identity = $iNg },
            [pscustomobject]@{ pid = 108; ramMB = 100; cpu = 1; protected = $false; identity = $iBuild }))
    Assert ($wls.Count -eq 2 -and $wls[0].key -eq 'devserver|dxwms' -and $wls[1].count -eq 2 -and $wls[1].ramMB -eq 500 -and @($wls[1].pids).Count -eq 2) 'workloads: gộp theo khoá, sắp theo RAM giảm dần'
    $hs = Hide-RgCmdSecret 'app.exe --password hunter2 --token=abc123 -p s3cret apikey=XYZ&x=1 --name ok'
    Assert ($hs -notmatch 'hunter2|abc123|s3cret|XYZ' -and $hs -match '--name ok') 'identity: Hide-RgCmdSecret che password/token/-p/apikey, giữ phần còn lại'
    $gpw = Get-RgProcTop @([pscustomobject]@{ pid = 1; name = 'aaa'; cpu = 1.0; ramMB = 10 }, [pscustomobject]@{ pid = 2; name = 'aaa'; cpu = 1.0; ramMB = 90 }) 12 8 @{ 1 = 'x|1'; 2 = 'x|2' }
    Assert (@($gpw)[0].workload -eq 'x|2') 'procTop: thêm workload của tiến trình nặng nhất trong nhóm; không truyền map thì không có trường'
    Assert (-not (@(Get-RgProcTop @([pscustomobject]@{ pid = 1; name = 'aaa'; cpu = 1.0; ramMB = 10 }))[0].PSObject.Properties['workload'])) 'procTop: bản ghi không có workload vẫn hợp lệ (tương thích cũ)'
    function Add-FakeMetric([datetime]$When, [string]$ProcName, [double]$Cpu, [int]$Ram, [int]$N) {
        $r = [ordered]@{ ts = $When.ToString('yyyy-MM-dd HH:mm:ss'); totalRamGB = 15.89; procTop = @([ordered]@{ name = $ProcName; n = $N; cpu = $Cpu; ramMB = $Ram }, [ordered]@{ name = 'other-proc'; n = 1; cpu = 0.5; ramMB = 10 }) }
        Add-Content -LiteralPath (Join-Path $home_ ('state\metrics-{0}.jsonl' -f $When.ToString('yyyyMMdd'))) -Value (ConvertTo-Json -InputObject $r -Compress) -Encoding UTF8
    }
    $tNow = Get-Date
    Add-FakeMetric $tNow.AddMinutes(-90) 'histproc' 1.0 900 9    # ngoài cửa sổ 60 phút
    Add-FakeMetric $tNow.AddMinutes(-30) 'histproc' 10.5 1200 7
    Add-FakeMetric $tNow.AddMinutes(-20) 'noproc' 1.0 5 1        # không có histproc: điểm thiếu bị bỏ
    Add-FakeMetric $tNow.AddMinutes(-10) 'histproc' 20.0 1683 8
    $h60 = Get-RgProcHistory 'histproc' 60
    Assert ($h60.name -eq 'histproc' -and @($h60.points).Count -eq 2 -and $h60.points[0].ramMB -eq 1200 -and $h60.points[1].ramMB -eq 1683 -and $h60.points[1].cpu -eq 20 -and $h60.points[1].n -eq 8) 'history: đúng điểm trong cửa sổ 60 phút, đúng thứ tự, bỏ điểm thiếu'
    Assert ($h60.totalRamMB -eq 16271 -or $h60.totalRamMB -eq 16270) 'history: totalRamMB = totalRamGB * 1024'
    Assert (@((Get-RgProcHistory 'histproc' 1440).points).Count -eq 3) 'history: cửa sổ 1440 phút lấy thêm điểm cũ'
    Assert (@((Get-RgProcHistory 'histproc' 99999).points).Count -eq 3) 'history: min vượt 1440 bị chặn về 1440'
    Assert (@((Get-RgProcHistory 'khong-co-tien-trinh-nay' 60).points).Count -eq 0) 'history: tên không có -> mảng rỗng, không lỗi'
    Assert (@((Get-RgProcHistory 'HistProc' 60).points).Count -eq 2) 'history: tên không phân biệt hoa thường'
    $hBad = 0; foreach ($bn in '../etc', 'a;b', '', ('x' * 65), 'a"b') { try { [void](Get-RgProcHistory $bn 60) } catch { $hBad++ } }
    Assert ($hBad -eq 5) 'history: tên chứa ký tự lạ / rỗng / quá dài bị từ chối'
    Assert (@((Get-RgProcHistory 'histproc' 60 -MaxPoints 1).points).Count -eq 1) 'history: giới hạn số điểm trả về (lấy thưa)'

    # ---- Insight (P3): dự báo + sẵn sàng + mục tiêu về mức Ổn ----
    . (Join-Path $root 'scripts\rg-insight.ps1')
    $thr = Get-RgDiskThresholds $cfg 'C'
    function Make-Samples([double]$StartFree, [double]$SlopePerDay, [double]$Days) {
        $t0 = (Get-Date).AddDays(-$Days)
        $n = [int]($Days * 24)
        return @(0..$n | ForEach-Object { [pscustomobject]@{ t = $t0.AddHours($_); freeGB = [math]::Round($StartFree + $SlopePerDay * ($_ / 24.0), 3) } })
    }
    $sm = Make-Samples 20 -0.9 11
    $f11 = Get-RgForecast $sm ([math]::Round(20 - 0.9 * 11, 3)) $thr
    Assert ([math]::Abs($f11.slopeGBPerDay - (-0.9)) -lt 0.01) 'forecast: dốc khớp -0,9 GB/ngày'
    Assert ([math]::Abs($f11.daysToFull - 11) -le 1 -and $f11.confidence -eq 'high' -and $f11.sampleDays -eq 11) 'forecast: giảm đều 0,9 GB/ngày -> daysToFull đúng ±1, 11 ngày dữ liệu = high'
    $f1gb = Get-RgForecast (Make-Samples 30 -1.0 5) 25 $thr
    Assert ([math]::Abs($f1gb.daysToFull - 25) -le 1 -and [math]::Abs($f1gb.daysToCaution - 5) -le 1 -and [math]::Abs($f1gb.daysToCritical - 15) -le 1 -and $f1gb.confidence -eq 'medium') 'forecast: 1 GB/ngày từ 25 GB -> đầy 25, Cần chú ý 5, Nguy cấp 15 (±1), 5 ngày = medium'
    $fLow = Get-RgForecast (Make-Samples 30 -1.0 1) 29 $thr
    Assert ($fLow.confidence -eq 'low' -and $null -eq $fLow.daysToFull -and $null -eq $fLow.daysToCaution -and $null -eq $fLow.daysToCritical) 'forecast: 1 ngày dữ liệu -> low, daysTo* = null'
    $fUp = Get-RgForecast (Make-Samples 20 0.5 10) 25 $thr
    Assert ($fUp.confidence -eq 'low' -and $null -eq $fUp.daysToFull) 'forecast: dốc dương -> low, daysTo* = null'
    $fOne = Get-RgForecast @([pscustomobject]@{ t = (Get-Date); freeGB = 10 }) 10 $thr
    Assert ($fOne.confidence -eq 'low' -and $null -eq $fOne.daysToFull -and (Get-RgForecast @() 10 $thr).confidence -eq 'low') 'forecast: 0-1 mẫu không lỗi, confidence low'
    $fNow = Get-RgForecast (Make-Samples 14 -0.5 5) 11.5 $thr
    Assert ($fNow.daysToCaution -eq 0 -and $fNow.daysToCritical -le 3) 'forecast: ổ đã dưới ngưỡng Ổn -> daysToCaution = 0'

    # Read-RgDriveSamples: lấy thưa mỗi giờ một điểm, theo từng ổ
    $oldDay = (Get-Date).AddDays(-5).Date.AddHours(8)
    $oldFile = Join-Path $home_ ('state\metrics-{0}.jsonl' -f $oldDay.ToString('yyyyMMdd'))
    $ln = foreach ($mi in 0, 15, 30, 45, 60, 75) {
        $w = $oldDay.AddMinutes($mi)
        ConvertTo-Json -InputObject ([ordered]@{ ts = $w.ToString('yyyy-MM-dd HH:mm:ss'); drives = @([ordered]@{ drive = 'C'; freeGB = (30 - $mi / 100.0) }, [ordered]@{ drive = 'D'; freeGB = 100 }) }) -Compress
    }
    Set-Content -LiteralPath $oldFile -Value $ln -Encoding UTF8
    $rs = Read-RgDriveSamples 14
    Assert ($rs.ContainsKey('C') -and $rs.ContainsKey('D') -and @($rs['C'] | Where-Object { $_.t.Date -eq $oldDay.Date }).Count -eq 2) 'samples: 6 dòng trong 2 giờ -> 2 điểm (mỗi giờ một điểm), có cả ổ D'
    Assert ($rs['C'][0].freeGB -eq 30 -and $rs['C'][0].t -lt $rs['C'][$rs['C'].Count - 1].t) 'samples: theo thứ tự thời gian, lấy dòng đầu mỗi giờ'
    Assert (@((Read-RgDriveSamples 2)['C'] | Where-Object { $_.t.Date -eq $oldDay.Date }).Count -eq 0) 'samples: ngoài số ngày yêu cầu bị bỏ'

    # Insight tổng hợp + readiness
    $tbl = @(Row 1 0 'explorer' '' 'other')
    $snapLow = [pscustomobject]@{ availRamGB = 2.1; diskFreeGB = 8.6; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 8.6; state = 'Critical' }) }
    $insLow = Get-RgInsight $snapLow $tbl @{ C = (Make-Samples 20 -0.9 11) } $cfg
    $rdTest = @($insLow.readiness | Where-Object task -eq 'test')[0]
    Assert (-not $rdTest.ok -and $rdTest.blocker -eq 'ram' -and $rdTest.needGB -eq 3 -and $rdTest.haveGB -eq 2.1) 'insight: RAM 2,1 GB -> test không đủ chỗ, blocker = ram'
    Assert ($insLow.drives[0].drive -eq 'C' -and $insLow.drives[0].state -eq 'Critical' -and $insLow.drives[0].goal.toState -eq 'Normal' -and $insLow.drives[0].goal.needGB -eq 11.4) 'insight: ổ C 8,6 GB -> cần thêm 11,4 GB để về Ổn'
    Assert ($insLow.ram.state -eq 'Restricted' -and $insLow.ram.goal.needGB -eq 2.9) 'insight: RAM 2,1 GB -> cần thêm 2,9 GB để về Ổn'
    $snapOk = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 50; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 50 }) }
    $insOk = Get-RgInsight $snapOk $tbl @{} $cfg
    Assert (@($insOk.readiness | Where-Object { -not $_.ok }).Count -eq 0 -and $null -eq $insOk.drives[0].goal.needGB -and $null -eq $insOk.ram.goal.needGB -and $insOk.drives[0].confidence -eq 'low') 'insight: máy ổn -> mọi tác vụ ok, goal.needGB = null, không có mẫu -> confidence low'
    $snapDisk = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 5; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 5 }) }
    Assert ((@((Get-RgInsight $snapDisk $tbl @{} $cfg).readiness | Where-Object task -eq 'build')[0]).blocker -eq 'disk') 'insight: ổ Nguy cấp, RAM dư -> build bị chặn vì disk'
    $tbl2 = $one + (Row 11 1 'dotnet' 'dotnet test b.sln' 'test')
    Assert ((@((Get-RgInsight $snapOk $tbl2 @{} $cfg).readiness | Where-Object task -eq 'build')[0]).blocker -eq 'concurrency') 'insight: đã đủ 2 tác vụ nặng -> blocker = concurrency'

    Write-Host "`n[policy] chính sách, vùng bảo vệ, PIN, engine tự dọn"
    . (Join-Path $root 'scripts\rg-policy.ps1')
    $hostExe = (Get-Process -Id $PID).Path
    NewFile (Join-Path $home_ 'state\rwtest.json') 5
    Assert ((Read-RgFileShared (Join-Path $home_ 'state\rwtest.json')).Length -eq 5) 'Read-RgFileShared đọc được file (đối số -bor trong ngoặc)'

    Write-Host "`n[advice] kế hoạch đề xuất tất định (P4)"
    $nowU = (Get-Date).ToUniversalTime()
    function AI([string]$Key, [string]$Kind, [string]$Path, [double]$GB, [string]$Action = 'delete', [bool]$Young = $false, [bool]$Admin = $false, [int]$Age = 30) {
        [pscustomobject]@{ key = $Key; kind = $Kind; action = $Action; path = $Path; drive = (Get-RgPathDrive $Path); sizeBytes = [long]($GB * 1GB); ageDays = $Age; newestWriteUtc = ''; young = $Young; needsAdmin = $Admin; name = ''; pid = 0 }
    }
    $advPol = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'dry-run'; protectPaths = @('C:\fake\prot') })
    $advItems = @(
        (AI 'k1' 'cache-aged' 'C:\fake\cache\nuget' 7.8), (AI 'k2a' 'dotnet-artifact' 'C:\fake\ws\a\obj' 2.0), (AI 'k2b' 'dotnet-artifact' 'C:\fake\ws\b\obj' 2.1),
        (AI 'k3' 'node_modules' 'C:\fake\ws\web\node_modules' 3.0), (AI 'k4' 'temp-entry' 'C:\fake\tmp\a' 0.01), (AI 'k5' 'temp-entry' 'C:\fake\tmp\b' 0.02),
        (AI 'k6' 'large-item' 'C:\fake\dl\bigzip' 2.0), (AI 'k7' 'node_modules' 'C:\fake\ws\new\node_modules' 0.5 'delete' $true $false 2), (AI 'k8' 'temp-entry' 'C:\fake\tmp\sys' 0.3 'report' $false $true),
        (AI 'k9' 'app' 'C:\fake\apps\old' 9.0 'report'), (AI 'k10' 'dotnet-artifact' 'C:\fake\prot\obj' 5.0), (AI 'k11' 'node_modules' 'C:\fake\dl\bigzip\node_modules' 0.1),
        (AI 'k12' 'dotnet-artifact' 'D:\proj\obj' 1.0), (AI 'k13' 'process' '' 0.2 'kill'))
    $advCand = [pscustomobject]@{ finishedUtc = $nowU.AddHours(-1).ToString('o'); items = $advItems }
    $advDrives = @([pscustomobject]@{ drive = 'D'; freeGB = 500 }, [pscustomobject]@{ drive = 'C'; freeGB = 8.6 })
    $adv = Get-RgAdvice $advCand @{} $null $advPol $advDrives $cfg $nowU
    $cSteps = @($adv.steps | Where-Object drive -eq 'C')
    Assert ($adv.goals.Count -eq 1 -and $adv.goals[0].drive -eq 'C' -and $adv.goals[0].needBytes -eq [long][math]::Ceiling(11.4 * 1GB) -and $adv.goals[0].toState -eq 'Normal') 'advice: mục tiêu = đưa ổ C (8,6 GB) về mức Ổn, cần 11,4 GB'
    Assert (-not $adv.stale -and $adv.candidatesUtc) 'advice: lượt quét mới (1 giờ) -> stale = false'
    $allKeys = @($adv.steps | ForEach-Object { $_.keys } | ForEach-Object { $_ })
    Assert (@('k9', 'k10', 'k13', 'k7', 'k8') | Where-Object { $allKeys -contains $_ } | ForEach-Object { $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }) 'advice: report / vùng bảo vệ / tiến trình / young / needsAdmin không vào bước'
    Assert (($adv.review.count -eq 2) -and $adv.review.keys -contains 'k7' -and $adv.review.keys -contains 'k8' -and $adv.review.bytes -eq [long](0.8 * 1GB)) 'advice: mục young và needsAdmin vào review (không tính mục bảo vệ/report)'
    Assert ($allKeys -notcontains 'k11') 'advice: mục nằm trong mục dọn khác bị bỏ để không đếm đôi'
    Assert ($cSteps[0].kind -eq 'cache-aged' -and $cSteps[1].kind -eq 'dotnet-artifact' -and $cSteps[2].kind -eq 'node_modules' -and $cSteps[3].kind -eq 'large-item' -and $cSteps[4].kind -eq 'temp-entry' -and $cSteps[4].minor -and -not $cSteps[0].minor) 'advice: sắp theo điểm bytes x regen x rủi ro (cache > bin/obj > node_modules > mục lớn), bước nhỏ (minor) cuối, giữ kind thật'
    Assert ($cSteps[1].count -eq 2 -and $cSteps[1].keys -contains 'k2a' -and $cSteps[1].keys -contains 'k2b' -and $cSteps[1].bytes -eq [long](4.1 * 1GB)) 'advice: gộp theo (ổ, kind): hai mục bin/obj thành một bước'
    Assert ($cSteps[4].count -eq 2 -and $cSteps[4].keys -contains 'k4' -and $cSteps[4].keys -contains 'k5' -and $cSteps[4].id -eq 'C:temp-entry' -and $cSteps[4].riskLevel -eq 'low' -and @($adv.steps | Where-Object kind -eq 'small').Count -eq 0) 'advice: bước < 50 MB giữ kind và riskLevel thật, minor=true, không còn kind small'
    $sumB = 0L; foreach ($s_ in $cSteps) { $sumB += [long]$s_.bytes }
    Assert ($cSteps[0].cumBytes -eq $cSteps[0].bytes -and $cSteps[1].cumBytes -eq ($cSteps[0].bytes + $cSteps[1].bytes) -and $cSteps[4].cumBytes -eq $sumB) 'advice: cumBytes cộng dồn'
    Assert (-not $cSteps[0].reachesGoal -and $cSteps[1].reachesGoal -and @($cSteps | Where-Object reachesGoal).Count -eq 1) 'advice: reachesGoal đúng ở bước đầu tiên làm tổng >= mục tiêu (7,8 + 4,1 >= 11,4)'
    Assert ($cSteps[0].auto -eq 'ask' -and $cSteps[1].auto -eq 'auto' -and $cSteps[2].auto -eq 'ask' -and $cSteps[3].auto -eq 'ask') 'advice: auto lấy theo chính sách nhóm (cache hỏi, bin/obj tự động)'
    Assert ($cSteps[0].riskLevel -eq 'low' -and $cSteps[0].regen -eq 'redownload' -and $cSteps[2].riskLevel -eq 'medium' -and $cSteps[3].riskLevel -eq 'high' -and $cSteps[0].why -and $cSteps[0].impact -and $cSteps[0].regenHint) 'advice: bước mang riskLevel/regen/why/impact/regenHint (dựng từ biên lai khi lượt quét cũ chưa có)'
    Assert ($adv.steps[0].drive -eq 'C' -and @($adv.steps | Where-Object drive -eq 'D').Count -eq 1 -and @($adv.steps | Where-Object drive -eq 'D')[0].reachesGoal -eq $false) 'advice: ổ có mục tiêu đứng trước; ổ không có mục tiêu có bước nhưng reachesGoal = false'
    $apC = @($adv.afterPlan | Where-Object drive -eq 'C')[0]; $apD = @($adv.afterPlan | Where-Object drive -eq 'D')[0]
    Assert ($apC.state -eq 'Normal' -and $apC.shortBytes -eq 0 -and $apC.freeGB -gt 20 -and $apD.state -eq 'Normal' -and $adv.beyond.Count -eq 0) 'advice: afterPlan = Ổn, shortBytes = 0, không có beyond khi dọn đủ'

    # dọn hết vẫn thiếu -> beyond từ lượt quét ổ (bỏ nhóm dọn được)
    $bdC = [pscustomobject]@{ drive = 'C'; categories = @(
            [pscustomobject]@{ cat = 'programs'; bytes = [long](50 * 1GB) }, [pscustomobject]@{ cat = 'temp'; bytes = [long](9 * 1GB) }, [pscustomobject]@{ cat = 'documents'; bytes = [long](20 * 1GB) },
            [pscustomobject]@{ cat = 'app-data'; bytes = [long](10 * 1GB) }, [pscustomobject]@{ cat = 'downloads'; bytes = [long](3 * 1GB) }) }
    $advShort = Get-RgAdvice $advCand @{ C = $bdC } $null $advPol @([pscustomobject]@{ drive = 'C'; freeGB = 1.0 }) $cfg $nowU
    $apS = @($advShort.afterPlan)[0]
    Assert ($apS.shortBytes -gt 0 -and $apS.state -ne 'Normal' -and @($advShort.steps | Where-Object reachesGoal).Count -eq 0) 'advice: dọn hết vẫn thiếu -> shortBytes > 0, không bước nào reachesGoal'
    Assert ($advShort.beyond.Count -eq 3 -and $advShort.beyond[0].cat -eq 'programs' -and $advShort.beyond[1].cat -eq 'documents' -and $advShort.beyond[2].cat -eq 'app-data' -and $advShort.beyond[0].hint -match 'Ứng dụng') 'advice: beyond = 3 nhóm lớn nhất không dọn được (bỏ temp), kèm gợi ý'

    # nhiều nhóm: không còn giới hạn 5 bước và không gộp vào "Các mục nhỏ"
    $many = @((AI 'm1' 'temp-entry' 'C:\m\t' 0.06), (AI 'm2' 'dotnet-artifact' 'C:\m\o' 0.5), (AI 'm3' 'node_modules' 'C:\m\n' 0.5), (AI 'm4' 'cache-aged' 'C:\m\c' 0.5), (AI 'm5' 'stale-repo' 'C:\m\r' 0.5), (AI 'm6' 'large-item' 'C:\m\l' 0.5))
    $advMany = Get-RgAdvice ([pscustomobject]@{ finishedUtc = $nowU.ToString('o'); items = $many }) @{} $null $advPol @([pscustomobject]@{ drive = 'C'; freeGB = 100 }) $cfg $nowU
    Assert (@($advMany.steps).Count -eq 6 -and @($advMany.steps | Where-Object kind -eq 'small').Count -eq 0 -and @($advMany.steps | ForEach-Object { $_.count } | Measure-Object -Sum).Sum -eq 6) 'advice: 6 nhóm -> 6 bước, không gộp "Các mục nhỏ", không mất mục'

    # RAM (P3 plan-ux-clarity): bước đóng ứng dụng theo workload
    function WL([string]$Key, [string]$Role, [string]$Title, [int]$Mb, [bool]$Prot = $false, [string]$Proj = '') { [pscustomobject]@{ key = $Key; role = $Role; title = $Title; project = $Proj; what = "Đang chạy $Title"; count = 2; ramMB = $Mb; cpuPct = 1.0; pids = @(1, 2); protected = $Prot } }
    $wlAll = @((WL 'agent|c' 'agent' 'Trợ lý AI' 3000), (WL 'system|s' 'system' 'Dịch vụ Windows' 2500), (WL 'unknown|u' 'unknown' 'abc' 2400), (WL 'browser|edge' 'browser' 'Trình duyệt' 1500),
        (WL 'devserver|dxwms' 'devserver' 'Angular dev server' 1200 $false 'dxwms'), (WL 'editor|code' 'editor' 'Trình soạn thảo code' 900), (WL 'app|prot' 'app' 'Được bảo vệ' 2000 $true), (WL 'app|tiny' 'app' 'Nhỏ' 50), (WL 'app|x' 'app' 'Ứng dụng X' 400))
    $advRam1 = Get-RgAdvice ([pscustomobject]@{ finishedUtc = $nowU.ToString('o'); items = @() }) @{} $null $advPol @([pscustomobject]@{ drive = 'C'; freeGB = 100 }) $cfg $nowU ([pscustomobject]@{ availGB = 2.1; totalGB = 16 }) $wlAll
    $rs = @($advRam1.steps)
    Assert ($rs.Count -ge 1 -and $rs[0].kind -eq 'close-app' -and $rs[0].resource -eq 'ram' -and $rs[0].actionType -eq 'close-app' -and $rs[0].manual -and $rs[0].workload -eq 'browser|edge') 'advice RAM: thiếu RAM + ổ Ổn -> bước đầu là close-app (workload nặng nhất được phép), manual = true'
    Assert (@($rs | Where-Object { $_.workload -match '^(agent|system|unknown)\|' -or $_.workload -eq 'app|prot' -or $_.workload -eq 'app|tiny' }).Count -eq 0) 'advice RAM: không đề xuất agent/system/unknown/workload được bảo vệ/workload < 100 MB'
    Assert ($rs.Count -le 3 -and $rs[0].impact -match 'chưa lưu' -and $rs[0].why -match 'Đang chạy' -and $rs[0].riskLevel -eq 'medium') 'advice RAM: tối đa 3 bước, impact nhắc việc chưa lưu, why lấy identity.what'
    $ramGoal = @($advRam1.goals | Where-Object resource -eq 'ram')[0]
    Assert ($ramGoal.needBytes -eq [long][math]::Ceiling((5 - 2.1) * 1GB) -and $ramGoal.state -eq 'Restricted') 'advice RAM: goal ram { needBytes, state }'
    $apR = @($advRam1.afterPlan | Where-Object resource -eq 'ram')[0]
    Assert ($apR.stateBefore -eq 'Restricted' -and $apR.afterBytes -gt $apR.beforeBytes -and $apR.shortBytes -eq 0 -and $apR.stateAfter -eq 'Normal') 'advice RAM: afterPlan ram có before/after và trạng thái trước -> sau'
    Assert (@($rs | Where-Object reachesGoal).Count -eq 1 -and $rs[-1].reachesGoal) 'advice RAM: dừng ở bước đầu tiên đủ đưa RAM về Ổn'
    $advRamOk = Get-RgAdvice ([pscustomobject]@{ finishedUtc = $nowU.ToString('o'); items = @() }) @{} $null $advPol @() $cfg $nowU ([pscustomobject]@{ availGB = 9; totalGB = 16 }) $wlAll
    Assert (@($advRamOk.steps).Count -eq 0 -and @($advRamOk.goals | Where-Object resource -eq 'ram').Count -eq 0) 'advice RAM: RAM Ổn -> không có bước/goal RAM'
    # cả hai cùng thiếu: tài nguyên xấu hơn đứng trước (RAM Nguy cấp hơn ổ Cần chú ý -> RAM trước; ổ Nguy cấp hơn RAM Cần chú ý -> ổ trước)
    $advBothA = Get-RgAdvice $advCand @{} $null $advPol @([pscustomobject]@{ drive = 'C'; freeGB = 15 }) $cfg $nowU ([pscustomobject]@{ availGB = 1.5; totalGB = 16 }) $wlAll
    Assert (@($advBothA.steps)[0].resource -eq 'ram') 'advice RAM: RAM Nguy cấp + ổ Cần chú ý -> bước RAM đứng trước'
    $advBothB = Get-RgAdvice $advCand @{} $null $advPol @([pscustomobject]@{ drive = 'C'; freeGB = 5 }) $cfg $nowU ([pscustomobject]@{ availGB = 4; totalGB = 16 }) $wlAll
    Assert (@($advBothB.steps)[0].resource -eq 'disk') 'advice RAM: ổ Nguy cấp + RAM Cần chú ý -> bước dọn ổ đứng trước'

    # ---- ngưỡng trạng thái + tóm tắt 7 ngày (P4 plan-ux-clarity) ----
    $thCfg = Get-RgConfig
    $thOk = Test-RgThresholdInput ([pscustomobject]@{ ramAvailGB = [pscustomobject]@{ normalAbove = 6; cautionFrom = 4; restrictedFrom = 2 } }) $thCfg
    Assert ($thOk.ok -and $thOk.merged.ramAvailGB.normalAbove -eq 6 -and $thOk.merged.diskFreeGB.normalAbove -eq [double]$thCfg.disk.normalAboveGB) 'thresholds: gửi một phần -> phần thiếu lấy từ cấu hình hiện tại'
    Assert (-not (Test-RgThresholdInput ([pscustomobject]@{ ramAvailGB = [pscustomobject]@{ normalAbove = 3; cautionFrom = 4 } }) $thCfg).ok) 'thresholds: thứ tự sai (Ổn <= Cần chú ý) bị từ chối'
    Assert (-not (Test-RgThresholdInput ([pscustomobject]@{ diskFreeGB = [pscustomobject]@{ normalAbove = 10; cautionFrom = 10 } }) $thCfg).ok) 'thresholds: ổ đĩa Ổn = Cần chú ý bị từ chối'
    Assert (-not (Test-RgThresholdInput ([pscustomobject]@{ commitPct = [pscustomobject]@{ restricted = 95; critical = 90 } }) $thCfg).ok) 'thresholds: commit Hạn chế >= Nguy cấp bị từ chối'
    Assert (-not (Test-RgThresholdInput ([pscustomobject]@{ ramAvailGB = [pscustomobject]@{ normalAbove = -5 } }) $thCfg).ok -and -not (Test-RgThresholdInput ([pscustomobject]@{ ramAvailGB = [pscustomobject]@{ normalAbove = 'abc' } }) $thCfg).ok) 'thresholds: số âm hoặc không phải số bị từ chối'
    $thOld = (Test-RgThresholdInput ([pscustomobject]@{}) $thCfg).merged
    $thLoose = (Test-RgThresholdInput ([pscustomobject]@{ diskFreeGB = [pscustomobject]@{ normalAbove = [double]$thCfg.disk.normalAboveGB - 5 } }) $thCfg).merged
    $thTight = (Test-RgThresholdInput ([pscustomobject]@{ diskFreeGB = [pscustomobject]@{ normalAbove = [double]$thCfg.disk.normalAboveGB + 5 } }) $thCfg).merged
    Assert ((Test-RgThresholdsLoosened $thOld $thLoose) -and -not (Test-RgThresholdsLoosened $thOld $thTight) -and -not (Test-RgThresholdsLoosened $thOld $thOld)) 'thresholds: hạ ngưỡng trống = nới lỏng; nâng ngưỡng hoặc giữ nguyên thì không'
    Save-RgThresholds $thTight
    $thBack = Get-RgConfig
    Assert ([double]$thBack.disk.normalAboveGB -eq [double]$thCfg.disk.normalAboveGB + 5 -and $thBack.identity.rules) 'thresholds: ghi config.json rồi đọc lại đúng, không mất các khoá khác'
    Save-RgThresholds $thOld
    $wkNow = Get-Date
    function EV([string]$Ev, [double]$AgoHours, $Data) { [pscustomobject]@{ ts = $wkNow.AddHours(-$AgoHours).ToString('yyyy-MM-dd HH:mm:ss'); event = $Ev; data = $Data } }
    $wk = Get-RgWeekSummary @(
        (EV 'auto-run' 5 ([pscustomobject]@{ mode = 'on'; items = 3; freedBytes = 1000 })), (EV 'auto-run' 30 ([pscustomobject]@{ mode = 'on'; items = 1; freedBytes = 500 })),
        (EV 'auto-run' 8 ([pscustomobject]@{ mode = 'dry-run'; items = 4; freedBytes = 0; byKind = [pscustomobject]@{ a = [pscustomobject]@{ items = 2; bytes = 300 }; b = [pscustomobject]@{ items = 2; bytes = 200 } } })),
        (EV 'manual-cleanup' 2 ([pscustomobject]@{ items = 2; freedBytes = 70 })), (EV 'auto-run' (24 * 9) ([pscustomobject]@{ mode = 'on'; items = 9; freedBytes = 9999 })),
        (EV 'state-change' 3 ([pscustomobject]@{ from = 'Normal'; to = 'Critical' })), (EV 'state-change' 2 ([pscustomobject]@{ from = 'Critical'; to = 'Normal' })), (EV 'state-change' 1 ([pscustomobject]@{ from = 'Normal'; to = 'Caution' }))) $wkNow
    Assert ($wk.autoRuns -eq 2 -and $wk.autoBytes -eq 1500 -and $wk.dryRuns -eq 1 -and $wk.dryBytes -eq 500 -and $wk.manualRuns -eq 1 -and $wk.manualBytes -eq 70 -and $wk.alerts -eq 2) 'week: đếm lượt tự dọn / chạy thử / dọn tay / cảnh báo trong 7 ngày, bỏ sự kiện cũ hơn 7 ngày'
    Assert ($null -ne (Get-RgInsight $snapOk $tbl @{} $cfg @()).week -and (Get-RgInsight $snapOk $tbl @{} $cfg @()).week.autoRuns -eq 0) 'week: /api/insight có trường week'

    # stale
    $advStale = Get-RgAdvice ([pscustomobject]@{ finishedUtc = $nowU.AddHours(-7).ToString('o'); items = @() }) @{} $null $advPol @() $cfg $nowU
    Assert ($advStale.stale -and @($advStale.steps).Count -eq 0) 'advice: lượt quét cũ hơn 6 giờ -> stale = true'
    Assert ((Get-RgAdvice $null @{} $null $advPol @() $cfg $nowU).stale) 'advice: chưa có lượt quét ứng viên -> stale, không lỗi'

    # agent: chỉ dùng khi mới hơn lượt quét; keep rời bước nhưng không đổi thứ tự
    $agNew = [pscustomobject]@{ ok = $true; finishedUtc = $nowU.ToString('o'); result = [pscustomobject]@{ recommendations = @(
                [pscustomobject]@{ key = 'k1'; verdict = 'keep'; confidence = 'high'; reason = 'đang dùng' }, [pscustomobject]@{ key = 'k2a'; verdict = 'clean'; confidence = 'medium'; reason = 'build cũ' }) } }
    $advAg = Get-RgAdvice $advCand @{} $agNew $advPol $advDrives $cfg $nowU
    $agC = @($advAg.steps | Where-Object drive -eq 'C')
    Assert ($agC[0].kind -eq 'dotnet-artifact' -and $agC[1].kind -eq 'node_modules' -and -not ($agC | Where-Object kind -eq 'cache-aged') -and $agC[0].agent.verdict -eq 'clean' -and $agC[0].agent.reason -eq 'build cũ') 'advice: key agent "keep" rời bước; bước còn lại giữ thứ tự và gắn nhãn agent'
    Assert ($agC[0].cumBytes -eq $agC[0].bytes -and $agC[0].keys.Count -eq 2) 'advice: cumBytes tính lại sau khi agent bỏ mục'
    $agOld = [pscustomobject]@{ ok = $true; finishedUtc = $nowU.AddHours(-3).ToString('o'); result = $agNew.result }
    $advAgOld = Get-RgAdvice $advCand @{} $agOld $advPol $advDrives $cfg $nowU
    Assert ((@($advAgOld.steps | Where-Object { $_.kind -eq 'cache-aged' }).Count -eq 1) -and $null -eq @($advAgOld.steps)[0].agent) 'advice: kết quả agent cũ hơn lượt quét ứng viên bị bỏ qua'
    [void](Add-RgAgentKeep 'C:\fake\ws\web\node_modules' 'agent giữ' 'high')
    $advK = Get-RgAdvice $advCand @{} $null $advPol $advDrives $cfg $nowU
    Assert (@($advK.steps | ForEach-Object { $_.keys } | ForEach-Object { $_ }) -notcontains 'k3') 'advice: mục agent-keep (còn hạn) không vào bước'
    $akm = Get-RgAgentKeepMatch 'C:\fake\ws\web\node_modules'; if ($akm) { [void](Remove-RgAgentKeep ([string]$akm.target)) }

    Write-Host "`n[priority] hạ ưu tiên tiến trình, đảo ngược được (P6)"
    . (Join-Path $root 'scripts\rg-proc.ps1')
    function StartStamp([int]$ProcId) { ConvertTo-RgStamp (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId").CreationDate }
    function PClass([int]$ProcId) { (Get-Process -Id $ProcId).PriorityClass.ToString() }
    $prA = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $prA
    $prB = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $prB
    Start-Sleep -Milliseconds 800
    $sA = StartStamp $prA.Id; $sB = StartStamp $prB.Id
    $priPath = Get-RgProcPriorityPath
    Assert ((PClass $prA.Id) -eq 'Normal') 'priority: tiến trình thử bắt đầu ở mức Normal'
    $t0 = Test-RgProcLowerable $prA.Id $sA
    Assert ($t0.ok -and $t0.name -eq 'ping' -and $t0.current -eq 'Normal') 'priority: Test-RgProcLowerable chấp nhận tiến trình thường (ping)'
    $r1 = Set-RgProcPriority $prA.Id $sA 'below'
    Assert ($r1.ok -and $r1.from -eq 'Normal' -and $r1.to -eq 'BelowNormal' -and (PClass $prA.Id) -eq 'BelowNormal') 'priority: hạ ưu tiên -> BelowNormal'
    $lst = @(Read-RgProcPriority)
    Assert ($lst.Count -eq 1 -and $lst[0].pid -eq $prA.Id -and $lst[0].start -eq $sA -and $lst[0].name -eq 'ping') 'priority: ghi proc-priority.json (pid + start)'
    $logTxt = Get-ChildItem (Join-Path $home_ 'logs') -Filter 'rg-*.jsonl' | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 } | Where-Object { $_ -match '"event":"proc-priority"' } | Select-Object -Last 1
    Assert ($logTxt -match '"from":"Normal"' -and $logTxt -match '"to":"BelowNormal"' -and $logTxt -match "`"pid`":$($prA.Id)") 'priority: ghi log proc-priority {pid, name, from, to}'
    $r1b = Set-RgProcPriority $prA.Id $sA 'below'
    Assert (-not $r1b.ok -and $r1b.error -match 'Đã được hạ') 'priority: hạ lần hai bị từ chối ("đã được hạ")'
    $ctxL = New-RgProcContext
    Assert ($ctxL.lowered.ContainsKey("$($prA.Id)|$sA")) 'priority: bối cảnh nhận ra tiến trình đang bị hạ (cho nhãn + nút hoàn tác)'
    $r2 = Set-RgProcPriority $prA.Id $sA 'normal'
    Assert ($r2.ok -and $r2.to -eq 'Normal' -and (PClass $prA.Id) -eq 'Normal' -and @(Read-RgProcPriority).Count -eq 0) 'priority: hoàn tác trả đúng PriorityClass Normal và xoá mục khỏi file'
    $r2b = Set-RgProcPriority $prA.Id $sA 'normal'
    Assert (-not $r2b.ok -and $r2b.error -match 'chưa hạ') 'priority: "normal" cho tiến trình chưa bị hạ -> từ chối (không nâng mức của người khác)'

    # sai start time -> từ chối, không đổi gì
    $rBad = Set-RgProcPriority $prB.Id '20200101T000000Z' 'below'
    Assert (-not $rBad.ok -and $rBad.error -match 'PID được dùng lại|thay đổi' -and (PClass $prB.Id) -eq 'Normal') 'priority: sai start time -> từ chối, mức ưu tiên giữ nguyên'
    $rBad2 = Set-RgProcPriority $prB.Id 'not-a-stamp' 'below'
    Assert (-not $rBad2.ok -and (PClass $prB.Id) -eq 'Normal') 'priority: start không đúng định dạng -> từ chối'
    $rBad3 = Set-RgProcPriority $prB.Id $sB 'high'
    Assert (-not $rBad3.ok -and (PClass $prB.Id) -eq 'Normal') 'priority: level lạ (high) -> từ chối, không có đường nâng ưu tiên'

    # PID đã chết -> từ chối, không ném lỗi
    $prD = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $sD = StartStamp $prD.Id; $deadId = $prD.Id
    Stop-Process -Id $deadId -Force; [void]$prD.WaitForExit(5000)
    $threw = $false; $rD = $null
    try { $rD = Set-RgProcPriority $deadId $sD 'below' } catch { $threw = $true }
    Assert (-not $threw -and -not $rD.ok -and $rD.error -match 'không còn chạy|đã kết thúc') 'priority: PID đã chết -> từ chối, không ném lỗi'
    $rD2 = $null; try { $rD2 = Set-RgProcPriority $deadId $sD 'normal' } catch { $threw = $true }
    Assert (-not $threw -and -not $rD2.ok) 'priority: hoàn tác PID đã chết -> từ chối, không ném lỗi'
    $rZ = $null; try { $rZ = Set-RgProcPriority 0 $sD 'below' } catch { $threw = $true }
    Assert (-not $threw -and -not $rZ.ok) 'priority: PID 0 -> từ chối'

    # mục có PID không còn sống bị dọn khi đọc
    $prE = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $sE = StartStamp $prE.Id
    Assert ((Set-RgProcPriority $prE.Id $sE 'below').ok -and @(Read-RgProcPriority).Count -eq 1) 'priority: hạ tiến trình E'
    Stop-Process -Id $prE.Id -Force; [void]$prE.WaitForExit(5000)
    Assert (@(Read-RgProcPriority).Count -eq 0 -and ((Get-Content $priPath -Raw) -match '^\s*\[\s*\]\s*$')) 'priority: PID không còn sống bị dọn khỏi file khi đọc'

    # PID của chính server/test -> từ chối
    $rSelf = Set-RgProcPriority $PID (StartStamp $PID) 'below'
    Assert (-not $rSelf.ok -and $rSelf.error -match 'chính Resource Guard' -and (PClass $PID) -eq 'Normal') 'priority: PID của chính tiến trình đang chạy mã (server) -> từ chối'
    Assert ((Get-RgProcLowerVerdict 4242 'powershell' 'other' 'pwsh -File C:\x\scripts\rg-scan.ps1 -Mode breakdown' 1 $ctxL) -match 'chính Resource Guard') 'priority: job nền rg-*.ps1 nhận ra qua dòng lệnh -> từ chối'

    # nhóm agent / infra / tên bảo vệ / ledger -> từ chối (dùng tiến trình thật + đổi cấu hình tạm)
    $cfgPath = Join-Path $home_ 'config.json'; $cfgOrig = [IO.File]::ReadAllText($cfgPath)
    try {
        foreach ($g in 'infra', 'agent') {
            $cg = ConvertFrom-Json $cfgOrig; $cg.groups.dev = @(); $cg.groups.$g = @('ping')
            [IO.File]::WriteAllText($cfgPath, (ConvertTo-Json $cg -Depth 8), (New-Object Text.UTF8Encoding $false))
            $rg = Set-RgProcPriority $prB.Id $sB 'below'
            Assert (-not $rg.ok -and (PClass $prB.Id) -eq 'Normal' -and (Get-Process -Id $prB.Id -ErrorAction SilentlyContinue)) "priority: nhóm '$g' -> từ chối, tiến trình còn nguyên"
        }
    } finally { [IO.File]::WriteAllText($cfgPath, $cfgOrig, (New-Object Text.UTF8Encoding $false)) }
    $polPathP = Get-RgPolicyPath; $polHad = Test-Path $polPathP; $polTxt = $null; if ($polHad) { $polTxt = [IO.File]::ReadAllText($polPathP) }
    try {
        [void](Save-RgPolicy (ConvertTo-RgPolicy ([pscustomobject]@{ protectProcesses = @('ping') })))
        $rP = Set-RgProcPriority $prB.Id $sB 'below'
        Assert (-not $rP.ok -and $rP.error -match 'vùng bảo vệ' -and (PClass $prB.Id) -eq 'Normal') 'priority: tên tiến trình trong vùng bảo vệ -> từ chối'
    } finally { if ($polHad) { [IO.File]::WriteAllText($polPathP, $polTxt, (New-Object Text.UTF8Encoding $false)) } else { Remove-Item $polPathP -Force -ErrorAction SilentlyContinue } }
    $prC = Start-Process ping -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru; $procs += $prC
    Start-Sleep -Milliseconds 500
    [void](Register-RgProcess -ProcId $prC.Id -Agent 'claude' -Label 'priority test' -OwnerPid $PID)
    $rL = Set-RgProcPriority $prC.Id (StartStamp $prC.Id) 'below'
    Assert (-not $rL.ok -and $rL.error -match 'trợ lý AI' -and (PClass $prC.Id) -eq 'Normal') 'priority: tiến trình trong ledger agent -> từ chối'
    Write-RgLedger @(Read-RgLedger | Where-Object { [int]$_.pid -ne $prC.Id })   # trả ledger như cũ cho các test sau

    # quyết định thuần: phiên 0 / phiên khác / tên hệ thống
    $vOk = Get-RgProcLowerVerdict 5000 'ping' 'dev' '' $ctxL.session $ctxL
    Assert ($vOk -eq '') 'priority: verdict thuần chấp nhận tiến trình thường cùng phiên'
    Assert ((Get-RgProcLowerVerdict 5000 'ping' 'dev' '' 0 $ctxL) -match 'phiên 0') 'priority: phiên 0 -> từ chối'
    Assert ((Get-RgProcLowerVerdict 5000 'ping' 'dev' '' ($ctxL.session + 7) $ctxL) -match 'phiên đăng nhập khác') 'priority: phiên khác -> từ chối'
    Assert ((Get-RgProcLowerVerdict 5000 'ping' 'dev' '' $null $ctxL) -match 'phiên') 'priority: không đọc được phiên -> từ chối'
    Assert ((Get-RgProcLowerVerdict 5000 'svchost' 'other' '' $ctxL.session $ctxL) -match 'hệ thống' -and (Get-RgProcLowerVerdict 5000 'explorer' 'other' '' $ctxL.session $ctxL) -match 'hệ thống') 'priority: svchost/explorer (hệ thống/giao diện) -> từ chối'
    Assert ((Get-RgProcLowerVerdict 5000 'claude' 'agent' '' $ctxL.session $ctxL) -match 'trợ lý' -and (Get-RgProcLowerVerdict 5000 'sqlservr' 'infra' '' $ctxL.session $ctxL) -match 'Hạ tầng') 'priority: nhóm agent / infra -> từ chối'
    Assert ((Get-RgProcLowerVerdict 4 'system' 'other' '' 0 $ctxL) -match 'hệ thống') 'priority: PID <= 4 -> từ chối'
    foreach ($pp in $procs) { if ($pp.Id -in $prA.Id, $prB.Id) { Assert (-not $pp.HasExited) 'priority: tiến trình thử vẫn sống sau mọi lần từ chối (không có đường kill)' } }
    $srvSrc = Get-Content (Join-Path $root 'scripts\rg-proc.ps1') -Raw
    # Từ B1 (plan-automation) rg-proc.ps1 có nút kết thúc, nhưng KHÔNG tự gọi API dừng tiến trình: chỉ đi qua Stop-RgProcessVerified (rg-common.ps1).
    Assert ($srvSrc -notmatch 'Stop-Process|\.Kill\(|taskkill|CloseMainWindow') 'priority: rg-proc.ps1 không tự gọi Stop-Process/Kill/taskkill/CloseMainWindow (kết thúc chỉ qua Stop-RgProcessVerified)'
    $priSrc = [regex]::Match($srvSrc, 'function Set-RgProcPriority.*?(?=\r?\n# =====)', 'Singleline').Value
    Assert ($priSrc -and $priSrc -notmatch 'Stop-RgProcessVerified|Invoke-RgProcEnd') 'priority: Set-RgProcPriority không có đường kết thúc tiến trình'

    Write-Host "`n[preview] xem trước chính sách + bằng chứng chạy thử (P5)"
    $pvCand = [pscustomobject]@{ finishedUtc = $nowU.ToString('o'); items = @(
            (AI 'p1' 'temp-entry' 'C:\fake\tmp\big' 5.0), (AI 'p2' 'dotnet-artifact' 'C:\fake\ws\x\obj' 2.0), (AI 'p3' 'cache-aged' 'C:\fake\cache\n' 3.0), (AI 'p4' 'temp-entry' 'C:\fake\tmp\young' 1.0 'delete' $true $false 2)) }
    $pvLowC = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 8.6; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 8.6; totalGB = 200 }) }
    $pvOkC = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 50; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 50; totalGB = 200 }) }
    $pvDraft = [pscustomobject]@{ mode = 'dry-run'; targetFreeGB = 25; categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'cache-aged' = 'ask'; 'node_modules' = 'keep'; 'process' = 'ask' } }
    $pvCur = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'cache-aged' = 'ask'; 'node_modules' = 'keep'; 'process' = 'ask' } })
    $polFileBefore = $null; if (Test-Path (Get-RgPolicyPath)) { $polFileBefore = [IO.File]::ReadAllText((Get-RgPolicyPath)) }
    $pv = Get-RgAutoPreview $pvDraft $pvCand $pvLowC $pvCur @{} @() $cfg
    $polFileAfter = $null; if (Test-Path (Get-RgPolicyPath)) { $polFileAfter = [IO.File]::ReadAllText((Get-RgPolicyPath)) }
    Assert (($polFileBefore -ceq $polFileAfter) -and (Get-RgPolicy).mode -ne 'dry-run') 'preview: bản nháp KHÔNG bị lưu (policy.json giữ nguyên, mode đang lưu không đổi)'
    # so với engine thật với cùng đầu vào
    $pvPol = ConvertTo-RgPolicy $pvDraft
    $pvStress = Get-RgStressInfo $pvPol $cfg $pvLowC
    foreach ($d_ in @($pvStress.drives)) { if ([string]$d_.trigger -ne 'off') { $d_.stress = $true; $pvStress.diskStress = $true } }
    if ([string]$pvPol.ramTrigger -ne 'off') { $pvStress.ramStress = $true }
    $direct = Select-RgAutoItems @($pvCand.items) $pvPol $pvStress
    Assert ((@($pv.forced.selected | ForEach-Object { $_.key }) -join ',') -eq (@($direct.selected | ForEach-Object { $_.key }) -join ',') -and @($pv.forced.selected).Count -eq 2) 'preview: forced.selected khớp Select-RgAutoItems với cùng đầu vào (temp + bin/obj)'
    Assert ($pv.forced.selected[0].kind -eq 'temp-entry' -and $pv.forced.selected[0].drive -eq 'C' -and $pv.forced.selected[0].sizeBytes -eq [long](5 * 1GB) -and $pv.forced.selected[0].target -eq 'C:\fake\tmp\big') 'preview: mục chọn có key/kind/target/sizeBytes/drive'
    $sk = @($pv.forced.skipped | ForEach-Object { $_.kind + ':' + $_.reason })
    Assert (@($pv.forced.skipped | Where-Object { $_.kind -eq 'cache-aged' -and $_.reason -match 'ask' }).Count -eq 1 -and @($pv.forced.skipped | Where-Object { $_.reason -match 'young|dưới ngưỡng tuổi' }).Count -eq 1) 'preview: forced.skipped nêu lý do (nhóm ở chế độ hỏi, mục young)'
    $pd = @($pv.forced.perDrive)[0]
    Assert ($pd.drive -eq 'C' -and $pd.freeGB -eq 8.6 -and $pd.afterGB -eq 15.6 -and $pd.stateBefore -eq 'Critical' -and $pd.stateAfter -eq 'Caution' -and $pd.targetFreeGB -eq 25 -and $pv.forced.kills -eq 0) 'preview: perDrive trước -> sau (8,6 -> 15,6 GB, Nguy cấp -> Cần chú ý) + kills = 0'
    Assert ($pv.now.wouldRun -and $pv.now.because -match 'Ổ C' -and $pv.now.because -match 'Chạy thử') 'preview: now.wouldRun = true khi ổ tới ngưỡng, nói rõ chế độ Chạy thử'
    $pvNo = Get-RgAutoPreview $pvDraft $pvCand $pvOkC $pvCur @{} @() $cfg
    Assert (-not $pvNo.now.wouldRun -and $pvNo.now.because -match 'chưa tới ngưỡng kích hoạt') 'preview: now.wouldRun = false khi ổ còn rộng'
    Assert (@($pvNo.forced.selected).Count -eq 0 -and @($pvNo.forced.skipped | Where-Object { $_.reason -match 'đủ dung lượng mục tiêu' }).Count -ge 1 -and $pvNo.forced.perDrive[0].afterGB -eq 50) 'preview: máy đang ổn (50 GB >= mục tiêu 25) -> forced không chọn thêm, lý do "đã đủ dung lượng mục tiêu"'
    $pvOff = Get-RgAutoPreview ([pscustomobject]@{ mode = 'off' }) $pvCand $pvLowC $pvCur @{} @() $cfg
    Assert (-not $pvOff.now.wouldRun -and $pvOff.now.because -match 'Tắt') 'preview: chế độ Tắt -> không chạy, nói rõ lý do'
    Assert (-not $pv.needsPin) 'preview: needsPin = false khi bản nháp chặt hơn/bằng (Chạy thử)'
    $pvLoose = [pscustomobject]@{ mode = 'on'; categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'cache-aged' = 'auto'; 'node_modules' = 'keep'; 'process' = 'ask' } }
    Assert ((Get-RgAutoPreview $pvLoose $pvCand $pvLowC $pvCur @{} @() $cfg).needsPin) 'preview: needsPin = true khi nới lỏng lúc chế độ Bật (cache: Hỏi -> Tự động)'
    $pvSame = [pscustomobject]@{ mode = 'on'; categories = $pvDraft.categories }
    Assert (-not (Get-RgAutoPreview $pvSame $pvCand $pvLowC $pvCur @{} @() $cfg).needsPin) 'preview: needsPin = false khi bản nháp không nới lỏng chính sách đang lưu'
    $pvEmpty = Get-RgAutoPreview $pvDraft ([pscustomobject]@{ finishedUtc = ''; items = @() }) $pvLowC $pvCur @{} @() $cfg
    Assert (@($pvEmpty.forced.selected).Count -eq 0 -and $pvEmpty.ok) 'preview: danh sách ứng viên rỗng -> không chọn gì, không lỗi'

    # triggers14d: đếm lần đi từ nhẹ hơn lên >= ngưỡng kích hoạt của bản nháp
    $tt0 = (Get-Date).AddDays(-3)
    $series = 30, 30, 8, 8, 30, 30, 8, 30, 15, 8, 30
    $smC = @(0..($series.Count - 1) | ForEach-Object { [pscustomobject]@{ t = $tt0.AddHours($_); freeGB = [double]$series[$_] } })
    $smD = @(0..3 | ForEach-Object { [pscustomobject]@{ t = $tt0.AddHours($_); freeGB = [double]@(30, 5, 30, 5)[$_] } })
    $pvT = Get-RgAutoPreview ([pscustomobject]@{ mode = 'dry-run'; diskTrigger = 'Critical'; drives = [pscustomobject]@{ D = [pscustomobject]@{ diskTrigger = 'off' } } }) $pvCand $pvLowC $pvCur @{ C = $smC; D = $smD } @() $cfg
    $tc = @($pvT.triggers14d | Where-Object drive -eq 'C')[0]
    Assert ($tc.count -eq 3 -and $tc.lastUtc -and @($pvT.triggers14d | Where-Object drive -eq 'D').Count -eq 0) 'preview: triggers14d đếm đúng 3 lần chạm Nguy cấp ở ổ C; ổ D đặt "off" không có dòng'
    $pvT2 = Get-RgAutoPreview ([pscustomobject]@{ mode = 'dry-run'; diskTrigger = 'Caution' }) $pvCand $pvLowC $pvCur @{ C = $smC } @() $cfg
    Assert ((@($pvT2.triggers14d)[0]).count -eq 3) 'preview: ngưỡng Cần chú ý -> đếm lần vượt xuống <= 20 GB (rơi sâu hơn không tính lại)'
    $pvT3 = Get-RgAutoPreview ([pscustomobject]@{ mode = 'dry-run'; diskTrigger = 'Critical' }) $pvCand $pvLowC $pvCur @{ C = @() } @() $cfg
    Assert ((@($pvT3.triggers14d)[0]).count -eq 0 -and $null -eq (@($pvT3.triggers14d)[0]).lastUtc) 'preview: không có mẫu -> count 0, lastUtc null'

    # evidence từ log auto-run
    function EvEv([string]$Mode, $ByKind, [int]$HoursAgo) { [pscustomobject]@{ ts = (Get-Date).ToUniversalTime().AddHours(-$HoursAgo).ToString('o'); event = 'auto-run'; data = [pscustomobject]@{ mode = $Mode; byKind = $ByKind } } }
    $evs = @(
        (EvEv 'dry-run' ([pscustomobject]@{ 'temp-entry' = [pscustomobject]@{ items = 3; bytes = 1000 }; 'dotnet-artifact' = [pscustomobject]@{ items = 0; bytes = 0 } }) 48),
        (EvEv 'dry-run' ([pscustomobject]@{ 'temp-entry' = [pscustomobject]@{ items = 5; bytes = 2000 } }) 24),
        (EvEv 'on' ([pscustomobject]@{ 'temp-entry' = [pscustomobject]@{ items = 99; bytes = 99999 } }) 12),
        ([pscustomobject]@{ ts = (Get-Date).ToUniversalTime().AddHours(-6).ToString('o'); event = 'auto-run'; data = [pscustomobject]@{ mode = 'dry-run' } }),
        (EvEv 'dry-run' ([pscustomobject]@{ 'node_modules' = [pscustomobject]@{ items = 2; bytes = 500 } }) 3))
    $evd = Get-RgAutoEvidence $evs
    $evT = @($evd | Where-Object kind -eq 'temp-entry')[0]
    Assert ($evT.dryRuns -eq 2 -and $evT.items -eq 8 -and $evT.bytes -eq 3000 -and $evT.sinceUtc -eq $evs[0].ts) 'evidence: cộng các lượt chạy thử theo nhóm (2 lượt, 8 mục, 3000 byte), sinceUtc = lượt đầu'
    Assert (@($evd | Where-Object kind -eq 'dotnet-artifact').Count -eq 0 -and @($evd | Where-Object kind -eq 'node_modules')[0].dryRuns -eq 1) 'evidence: nhóm 0 mục không tính; lượt chạy thật và log cũ không có byKind bị bỏ qua'
    $pvE = Get-RgAutoPreview $pvDraft $pvCand $pvLowC $pvCur @{} $evs $cfg
    Assert (@($pvE.evidence).Count -eq 2) 'preview: evidence đi theo sự kiện đã cho'

    Write-Host "`n[setup] thông báo tiếng Việt + API thiết lập (P7)"
    Assert ((Get-RgStateVi 'Normal') -eq 'Ổn' -and (Get-RgStateVi 'Caution') -eq 'Cần chú ý' -and (Get-RgStateVi 'Restricted') -eq 'Hạn chế' -and (Get-RgStateVi 'Critical') -eq 'Nguy cấp') 'toast: tên trạng thái tiếng Việt Ổn / Cần chú ý / Hạn chế / Nguy cấp'
    $tsDisk = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 8.6; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 8.6 }) }
    $tbDisk = Get-RgBudget -Task session -Snapshot $tsDisk -Table @()
    $tt1 = Get-RgToastText 'Critical' $true $tbDisk $tsDisk $cfg
    Assert ($tt1.title -eq 'Resource Guard: Nguy cấp' -and $tt1.body -eq 'Ổ C còn 8,6 GB. Mở Resource Guard để xem kế hoạch dọn.') 'toast: ổ đầy -> "Ổ C còn 8,6 GB. Mở Resource Guard để xem kế hoạch dọn."'
    $tsRam = [pscustomobject]@{ availRamGB = 2.1; diskFreeGB = 50; commitPct = 40; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 50 }) }
    $tt2 = Get-RgToastText 'Restricted' $true (Get-RgBudget -Task session -Snapshot $tsRam -Table @()) $tsRam $cfg
    Assert ($tt2.title -eq 'Resource Guard: Hạn chế' -and $tt2.body -match '^RAM trống còn 2,1 GB' ) 'toast: RAM thấp -> câu về RAM kèm số liệu'
    $tsCommit = [pscustomobject]@{ availRamGB = 9; diskFreeGB = 50; commitPct = 92; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 50 }) }
    $tt3 = Get-RgToastText 'Restricted' $true (Get-RgBudget -Task session -Snapshot $tsCommit -Table @()) $tsCommit $cfg
    Assert ($tt3.body -match 'Bộ nhớ cam kết đã dùng 92%') 'toast: commit cao -> "Bộ nhớ cam kết" (thay Commit)'
    $tsBoth = [pscustomobject]@{ availRamGB = 2.1; diskFreeGB = 8.6; commitPct = 92; diskDrive = 'C'; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 8.6 }, [pscustomobject]@{ drive = 'D'; freeGB = 15 }) }
    $tt4 = Get-RgToastText 'Critical' $true (Get-RgBudget -Task session -Snapshot $tsBoth -Table @()) $tsBoth $cfg
    Assert ($tt4.body -match '^Ổ C còn 8,6 GB') 'toast: nhiều nguồn -> chọn nguồn nặng nhất (ổ Nguy cấp thắng RAM Hạn chế)'
    $tt5 = Get-RgToastText 'Normal' $false (Get-RgBudget -Task session -Snapshot $tsDisk -Table @()) $tsDisk $cfg
    Assert ($tt5.title -eq 'Resource Guard: máy đã ổn' -and $tt5.body -notmatch 'Normal') 'toast: hồi phục -> "máy đã ổn", không còn chữ Normal'
    Assert (($tt1.body + $tt2.body + $tt3.body + $tt4.body) -notmatch 'available RAM|free \d|->|commit charge') 'toast: không dán chuỗi reasons tiếng Anh thô'

    $script:fx = @()
    $fxEffects = @{ autostart = { param($on) $script:fx += "autostart=$on" }; shortcut = { param($on) $script:fx += "shortcut=$on" } }
    $fxProbe = { @{ autostart = $false; shortcut = $false } }
    $setupFile = Get-RgSetupFilePath
    Assert (-not (Test-Path $setupFile)) 'setup: chưa có state\setup.json'
    $si0 = Get-RgSetupInfo $fxProbe
    Assert ($si0.firstRun -eq $true -and $si0.autostart -eq $false -and $si0.shortcut -eq $false -and $si0.Contains('pinConfigured') -and $si0.Contains('mode')) 'setup: GET -> { autostart, shortcut, pinConfigured, mode, firstRun = true }'
    $sp1 = Invoke-RgSetupPost ([pscustomobject]@{ firstRunDone = $true }) $fxEffects $fxProbe
    Assert ($sp1.ok -and $sp1.info.firstRun -eq $false -and (Test-Path $setupFile) -and (Get-RgSetupInfo $fxProbe).firstRun -eq $false -and $script:fx.Count -eq 0) 'setup: firstRun chuyển false sau firstRunDone, không đụng autostart/shortcut'
    $sp2 = Invoke-RgSetupPost ([pscustomobject]@{ autostart = $true }) $fxEffects $fxProbe
    Assert ($sp2.ok -and ($script:fx -join ',') -eq 'autostart=True') 'setup: autostart:true -> gọi đúng hiệu ứng bật tự chạy (một lần)'
    $script:fx = @()
    $sp3 = Invoke-RgSetupPost ([pscustomobject]@{ autostart = $false; shortcut = $true }) $fxEffects $fxProbe
    Assert ($sp3.ok -and ($script:fx -join ',') -eq 'autostart=False,shortcut=True') 'setup: gộp autostart + shortcut trong một yêu cầu'
    $script:fx = @()
    $sp4 = Invoke-RgSetupPost ([pscustomobject]@{ autostart = 'yes' }) $fxEffects $fxProbe
    Assert (-not $sp4.ok -and $sp4.error -match 'true hoặc false' -and $script:fx.Count -eq 0) 'setup: giá trị không phải bool bị từ chối, không làm gì'
    $sp5 = Invoke-RgSetupPost ([pscustomobject]@{ pin = '1234'; evil = 1; setPin = $true }) $fxEffects $fxProbe
    Assert ($sp5.ok -and $script:fx.Count -eq 0 -and -not (Test-RgPinConfigured)) 'setup: khoá lạ (kể cả pin) bị bỏ qua, PIN KHÔNG đặt được qua API'
    Assert (-not (Invoke-RgSetupPost $null $fxEffects $fxProbe).ok) 'setup: thân yêu cầu rỗng -> từ chối'
    $fxThrow = @{ autostart = { param($on) throw 'bị từ chối' }; shortcut = { param($on) } }
    $sp6 = Invoke-RgSetupPost ([pscustomobject]@{ autostart = $true }) $fxThrow $fxProbe
    Assert (-not $sp6.ok -and $sp6.error -match 'bị từ chối') 'setup: hiệu ứng lỗi -> ok=false kèm lý do, không ném lỗi'
    Assert ((Get-Content (Get-ChildItem (Join-Path $home_ 'logs') -Filter 'rg-*.jsonl' | Select-Object -Last 1).FullName -Encoding UTF8 | Where-Object { $_ -match '"event":"setup-change"' }).Count -ge 3) 'setup: ghi log setup-change'
    Remove-Item $setupFile -Force -ErrorAction SilentlyContinue
    $p0 = Get-RgPolicy
    Assert ($p0.mode -eq 'off' -and $p0.categories['cache-aged'] -eq 'ask' -and $p0.categories['temp-entry'] -eq 'auto') 'policy: mặc định mode off, nhóm rủi ro cao không auto'
    $yPol = Get-RgPolicy; $yPol.categories['cache-aged'] = 'auto'
    $yStress = [pscustomobject]@{ diskStress = $true; ramStress = $false; drives = @(); diskFreeGB = 1; diskDrive = 'C' }
    $yPick = Select-RgAutoItems @((New-RgItem -Kind 'cache-aged' -Action 'delete' -Level 2 -Path $cache -AgeDays 0 -Young $true -Reason 'young test')) $yPol $yStress
    Assert (@($yPick.selected).Count -eq 0 -and (@($yPick.skipped)[0].reason -match 'ngưỡng tuổi')) 'young không bao giờ vào danh sách auto-clean dù policy = auto'
    $bad = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'nuke'; maxGBPerRun = 99999; categories = [pscustomobject]@{ 'cache-aged' = 'bogus'; 'evil' = 'auto' }; protectPaths = @('relative\x', 'C:\ok\path'); protectProcesses = @('SqlServr', "bad`nname") })
    Assert ($bad.mode -eq 'off' -and $bad.maxGBPerRun -eq 500) 'policy: mode lạ -> off, số vượt kẹp về giới hạn'
    Assert ($bad.categories['cache-aged'] -eq 'ask' -and -not $bad.categories.Contains('evil')) 'policy: giá trị nhóm lạ bị bỏ, nhóm lạ bị loại'
    Assert (@($bad.protectPaths).Count -eq 1 -and $bad.protectPaths[0] -eq 'C:\ok\path' -and @($bad.protectProcesses).Count -eq 1 -and $bad.protectProcesses[0] -eq 'sqlservr') 'policy: chỉ nhận đường dẫn tuyệt đối, tên tiến trình chữ thường, bỏ ký tự điều khiển'
    $keepDir = Join-Path $ws 'keepme'
    $pp = ConvertTo-RgPolicy ([pscustomobject]@{ protectPaths = @($keepDir); protectProcesses = @('node*', 'devenv') })
    Assert ((Test-RgPathProtected "$keepDir\obj" $pp) -and (Test-RgPathProtected $keepDir $pp)) 'protect: mục nằm trong/bằng thư mục bảo vệ'
    Assert ((Test-RgPathProtected $ws $pp) -and -not (Test-RgPathProtected "${keepDir}x" $pp) -and -not (Test-RgPathProtected (Join-Path $ws 'other') $pp)) 'protect: cha của vùng bảo vệ bị chặn, thư mục anh em tên gần giống thì không'
    Assert ((Test-RgProcessProtected 'nodemon' $pp) -and (Test-RgProcessProtected 'DevEnv' $pp) -and -not (Test-RgProcessProtected 'devenv2' $pp)) 'protect: tiến trình khớp wildcard, không phân biệt hoa thường'
    # agent giữ: bảo vệ có thời hạn, tách khỏi protectPaths của người dùng
    $akDir = Join-Path $ws 'agentkept'
    $akPol = Get-RgPolicy; $akPol.categories['temp-entry'] = 'auto'
    $akItem = New-RgItem -Kind 'temp-entry' -Action 'delete' -Level 1 -Path "$akDir\obj" -AgeDays 99 -Reason 'ak test'
    Assert (@((Select-RgAutoItems @($akItem) $akPol $yStress).selected).Count -eq 1) 'agent-keep: trước khi giữ, mục auto vào danh sách tự dọn'
    Assert (Add-RgAgentKeep $akDir 'dự án đang làm' 'high') 'agent-keep: thêm mục mới thành công'
    Assert (-not (Add-RgAgentKeep $akDir 'trùng' 'high')) 'agent-keep: đã giữ thì không thêm/gia hạn lần nữa'
    Assert ((Test-RgPathProtected "$akDir\obj" $akPol) -and (Test-RgPathProtected $akDir $akPol) -and (Test-RgPathProtected $ws $akPol) -and -not (Test-RgPathProtected "${akDir}x" $akPol)) 'agent-keep: con/chính nó/cha bị bảo vệ, thư mục anh em tên gần giống thì không'
    Assert (-not (Test-RgPathUserProtected "$akDir\obj" $akPol)) 'agent-keep: không lẫn vào protectPaths của người dùng'
    $akPick = Select-RgAutoItems @($akItem) $akPol $yStress
    Assert (@($akPick.selected).Count -eq 0 -and (@($akPick.skipped)[0].reason -match 'vùng bảo vệ')) 'agent-keep: auto-clean bỏ qua mục agent giữ'
    Assert (-not (Add-RgAgentKeep 'relative\x' 'x' 'high') -and -not (Add-RgAgentKeep "C:\bad`tpath" 'x' 'high')) 'agent-keep: đường dẫn tương đối/ký tự điều khiển bị từ chối'
    $akM = Get-RgAgentKeepMatch "$akDir\obj"
    Assert ($akM -and $akM.reason -eq 'dự án đang làm' -and (Remove-RgAgentKeep $akM.target)) 'agent-keep: bỏ giữ đúng mục khớp'
    Assert (-not (Test-RgPathProtected "$akDir\obj" $akPol) -and @((Select-RgAutoItems @($akItem) $akPol $yStress).selected).Count -eq 1) 'agent-keep: bỏ giữ xong thì lại dọn được'
    $akExp = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
    Write-RgFileAtomic (Get-RgAgentKeepPath) (ConvertTo-Json -InputObject ([ordered]@{ version = 1; items = @([ordered]@{ target = $akDir; reason = 'cũ'; confidence = 'high'; createdUtc = $akExp; expiresUtc = $akExp }) }) -Depth 4)
    Assert (-not (Test-RgPathProtected "$akDir\obj" $akPol)) 'agent-keep: mục hết hạn không còn bảo vệ'
    $off = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'off' }); $on =ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; protectProcesses = @('a') })
    $on2 = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; protectProcesses = @('a', 'b') })
    $onLoose = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; protectProcesses = @('a'); categories = [pscustomobject]@{ 'node_modules' = 'auto' } })
    Assert (Test-RgPolicyNeedsPin $off $on) 'pin: bật mode on từ off cần PIN'
    Assert (-not (Test-RgPolicyNeedsPin $on $on2)) 'pin: siết thêm bảo vệ khi đang on không cần PIN'
    Assert (Test-RgPolicyNeedsPin $on $onLoose) 'pin: nới nhóm ask->auto khi đang on cần PIN'
    Assert (-not (Test-RgPolicyNeedsPin $on $off)) 'pin: tắt về off không cần PIN'
    Assert (-not (Test-RgPinConfigured)) 'pin: chưa đặt'
    Assert ((Test-RgPin '1234').notConfigured) 'pin: chưa đặt thì Test-RgPin báo notConfigured'
    $threw = $false; try { Set-RgPin 'ab' } catch { $threw = $true }
    Assert $threw 'pin: PIN quá ngắn bị từ chối'
    Set-RgPin 'abcd1'
    Assert ((Test-RgPin 'abcd1').ok -and -not (Test-RgPin 'wrong').ok) 'pin: đúng/sai'
    $raw = Get-Content (Get-RgPinPath) -Raw
    Assert ($raw -notmatch 'abcd1' -and $raw -match 'iter' -and $raw -match 'salt') 'pin: chỉ lưu muối + băm PBKDF2, không lưu PIN'
    1..4 | ForEach-Object { [void](Test-RgPin 'nope') }
    $lk = Test-RgPin 'nope'
    Assert ($lk.locked -and $lk.retryAfterSec -gt 0) 'pin: sai 5 lần thì khoá'
    Assert (-not (Test-RgPin 'abcd1').ok) 'pin: đang khoá thì PIN đúng cũng không qua'
    Set-RgPin 'abcd1'
    Assert ((Test-RgPin 'abcd1').ok) 'pin: đặt lại PIN ở console gỡ khoá'

    # engine chọn mục
    $pe = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; targetFreeGB = 1000; protectPaths = @("$ws\prot"); protectProcesses = @('keepproc'); maxKillsPerRun = 1
            categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'node_modules' = 'ask'; 'process' = 'auto' } })
    $c1 = New-RgItem -Kind 'temp-entry' -Action delete -Level 1 -Path "$tmp\a" -SizeBytes 10MB
    $c2 = New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path "$ws\prot\obj" -SizeBytes 50MB
    $c3 = New-RgItem -Kind 'node_modules' -Action delete -Level 2 -Path "$ws\n\node_modules" -SizeBytes 100MB
    $c4 = New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path "$ws\free\obj" -SizeBytes 30MB
    $c5 = New-RgItem -Kind 'process' -Action kill -Level 1 -ProcId 99999 -Name 'keepproc' -SizeBytes 5MB
    $c6 = New-RgItem -Kind 'process' -Action kill -Level 1 -ProcId 99998 -Name 'worker' -SizeBytes 5MB
    $c7 = New-RgItem -Kind 'process' -Action kill -Level 1 -ProcId 99997 -Name 'worker2' -SizeBytes 4MB
    $c8 = New-RgItem -Kind 'vhdx' -Action report -Level 3 -Path "$ws\x.vhdx" -SizeBytes 5GB
    $stD = [pscustomobject]@{ diskStress = $true; ramStress = $false; diskFreeGB = 5; availRamGB = 8 }
    $pk = Select-RgAutoItems @($c1, $c2, $c3, $c4, $c5, $c8) $pe $stD
    $selPaths = @($pk.selected | ForEach-Object { $_.path })
    Assert ($selPaths -contains "$tmp\a" -and $selPaths -contains "$ws\free\obj" -and $pk.selected.Count -eq 2) 'engine: chỉ chọn nhóm auto, ngoài vùng bảo vệ, đúng loại áp lực (đĩa)'
    Assert ((@($pk.skipped | Where-Object { $_.reason -match 'bảo vệ' }).Count -eq 1) -and (@($pk.skipped | Where-Object { $_.reason -match 'ask' }).Count -eq 1)) 'engine: ghi lý do bỏ qua (vùng bảo vệ / nhóm ask)'
    Assert ($pk.selected[0].kind -eq 'temp-entry') 'engine: theo thứ tự ưu tiên (temp trước dotnet)'
    $stR = [pscustomobject]@{ diskStress = $false; ramStress = $true; diskFreeGB = 50; availRamGB = 1 }
    $pk2 = Select-RgAutoItems @($c1, $c5, $c6, $c7) $pe $stR
    Assert ($pk2.selected.Count -eq 1 -and $pk2.selected[0].name -eq 'worker') 'engine: RAM stress chỉ kill, tiến trình bảo vệ bị bỏ, giới hạn maxKillsPerRun'
    $pcap = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; targetFreeGB = 1000; maxGBPerRun = 0.1; categories = [pscustomobject]@{ 'temp-entry' = 'auto' } })
    $big = New-RgItem -Kind 'temp-entry' -Action delete -Level 1 -Path "$tmp\big" -SizeBytes 500MB
    Assert ((Select-RgAutoItems @($big) $pcap $stD).selected.Count -eq 0) 'engine: không vượt giới hạn GB mỗi lượt'
    $pn = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Critical'; ramTrigger = 'off' })
    $stress = Get-RgStressInfo $pn $cfg (Snap 8 30 40)
    Assert (-not $stress.diskStress -and -not $stress.ramStress) 'engine: ổ đĩa Caution chưa chạm trigger Critical, RAM trigger off'
    Assert ((Get-RgStressInfo $pn $cfg (Snap 8 5 40)).diskStress) 'engine: ổ đĩa Critical chạm trigger'
    Assert (-not (Test-RgAutoDue (ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'off' })) ([pscustomobject]@{ diskStress = $true; ramStress = $true }))) 'engine: mode off không bao giờ đến hạn'

    # ---- nhiều ổ đĩa: chính sách và áp lực tính riêng từng ổ ----
    $mp = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Critical'; drives = [pscustomobject]@{ d = [pscustomobject]@{ diskTrigger = 'Caution'; targetFreeGB = 40 }; zz = [pscustomobject]@{ diskTrigger = 'Caution' }; E = [pscustomobject]@{ diskTrigger = 'bogus' } } })
    Assert (@($mp.drives.Keys).Count -eq 1 -and $mp.drives['D'].diskTrigger -eq 'Caution' -and $mp.drives['D'].targetFreeGB -eq 40) 'drives: policy chuẩn hoá (chữ hoa, bỏ tên ổ/giá trị sai)'
    Assert (((Get-RgDrivePolicy $mp 'D').diskTrigger -eq 'Caution') -and ((Get-RgDrivePolicy $mp 'C').diskTrigger -eq 'Critical') -and ((Get-RgDrivePolicy $mp 'C').targetFreeGB -eq $mp.targetFreeGB)) 'drives: ổ có ghi đè dùng riêng, ổ khác thừa hưởng giá trị chung'
    $rt = ConvertTo-RgPolicy (ConvertFrom-Json (ConvertTo-Json -InputObject $mp -Depth 5))
    Assert ($rt.drives['D'].diskTrigger -eq 'Caution') 'drives: policy qua JSON vẫn giữ ghi đè theo ổ'
    $cfgD = $cfg | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    Add-Member -InputObject $cfgD.disk -NotePropertyName drives -NotePropertyValue ([pscustomobject]@{ D = [pscustomobject]@{ normalAboveGB = 100 } }) -Force
    Assert (((Get-RgDiskState 50 $cfgD 'D') -eq 'Caution') -and ((Get-RgDiskState 50 $cfgD 'C') -eq 'Normal')) 'drives: ngưỡng trạng thái theo ổ ghi đè ngưỡng chung'
    $mdl = @([pscustomobject]@{ drive = 'C'; freeGB = 50; totalGB = 200 }, [pscustomobject]@{ drive = 'D'; freeGB = 5; totalGB = 500 })
    $ms = [pscustomobject]@{ availRamGB = 9; commitPct = 40; diskDrive = 'C'; diskFreeGB = 50; drives = $mdl }
    $sD = Get-RgStressInfo $pn $cfg $ms
    Assert ($sD.diskStress -and ($sD.diskState -eq 'Critical') -and (-not (@($sD.drives | Where-Object { $_.drive -eq 'C' })[0].stress)) -and (@($sD.drives | Where-Object { $_.drive -eq 'D' })[0].stress)) 'drives: áp lực tính riêng từng ổ (D Critical, C bình thường)'
    $pOff = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Critical'; drives = [pscustomobject]@{ D = [pscustomobject]@{ diskTrigger = 'off' } } })
    Assert (-not (Get-RgStressInfo $pOff $cfg $ms).diskStress) 'drives: ổ đặt trigger off không bao giờ kích hoạt dù đầy'
    $bg = Get-RgBudget -Task build -Snapshot $ms -Table $t
    Assert (($bg.state -eq 'Critical') -and (@($bg.reasons | Where-Object { $_ -match 'disk D:' }).Count -eq 1) -and (@($bg.reasons | Where-Object { $_ -match 'disk C:' }).Count -eq 0)) 'drives: budget lấy trạng thái xấu nhất và nêu đúng ổ nào đầy'
    $selD = Select-RgAutoItems @((New-RgItem -Kind 'temp-entry' -Action delete -Level 1 -Path 'C:\Users\x\Temp\a' -SizeBytes 10MB), (New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path 'D:\Work\p\obj' -SizeBytes 20MB)) $mp $sD
    Assert (($selD.selected.Count -eq 1) -and ($selD.selected[0].path -eq 'D:\Work\p\obj') -and (@($selD.skipped | Where-Object { $_.reason -match 'ổ C: chưa tới ngưỡng' }).Count -eq 1)) 'drives: chỉ dọn mục nằm trên ổ đang chịu áp lực'
    $mpc = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Caution'; targetFreeGB = 1000; maxGBPerRun = 0.1; categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto' } })
    $sBoth = Get-RgStressInfo $mpc $cfg ([pscustomobject]@{ availRamGB = 9; commitPct = 40; diskDrive = 'C'; diskFreeGB = 5; drives = @([pscustomobject]@{ drive = 'C'; freeGB = 5; totalGB = 200 }, [pscustomobject]@{ drive = 'D'; freeGB = 5; totalGB = 500 }) })
    $capItems = @((New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path 'D:\w\a\obj' -SizeBytes 50MB), (New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path 'D:\w\b\obj' -SizeBytes 40MB), (New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path 'D:\w\c\obj' -SizeBytes 30MB), (New-RgItem -Kind 'dotnet-artifact' -Action delete -Level 1 -Path 'C:\w\a\obj' -SizeBytes 50MB))
    $pc = Select-RgAutoItems $capItems $mpc $sBoth
    Assert ((@($pc.selected | Where-Object { $_.path -like 'D:*' }).Count -eq 2) -and (@($pc.selected | Where-Object { $_.path -like 'C:*' }).Count -eq 1) -and (@($pc.skipped | Where-Object { $_.reason -match 'giới hạn GB mỗi lượt \(ổ D:\)' }).Count -eq 1)) 'drives: giới hạn GB mỗi lượt tính riêng từng ổ'
    Assert ((Get-RgPathDrive 'd:\x\y') -eq 'D' -and -not (Get-RgPathDrive '\\srv\share\x') -and -not (Get-RgPathDrive 'relative\p')) 'drives: Get-RgPathDrive'
    $oneD = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Critical' })
    $looseD = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; diskTrigger = 'Critical'; drives = [pscustomobject]@{ D = [pscustomobject]@{ diskTrigger = 'Caution' } } })
    Assert ((Test-RgPolicyNeedsPin $oneD $looseD) -and -not (Test-RgPolicyNeedsPin $looseD $oneD)) 'drives: nới trigger của MỘT ổ cần PIN, siết lại thì không'
    $drv = @(Get-RgDrives)
    Assert (($drv.Count -ge 1) -and (@($drv | Where-Object { $_.isSystem }).Count -eq 1) -and (@($drv | Where-Object { $_.drive -notmatch '^[A-Z]$' }).Count -eq 0)) 'drives: liệt kê ổ cố định, đúng một ổ hệ thống'
    Assert (@((Get-RgSnapshot -SkipCpu).drives).Count -eq $drv.Count) 'drives: snapshot kèm danh sách ổ'
    $cfgNoAuto = [pscustomobject]@{ workspaceRoots = @('%TEMP%\rg-x1'); autoRoots = $false }
    Assert ((@(Get-RgWorkspaceRoots $cfgNoAuto).Count -eq 1) -and ((@(Get-RgWorkspaceRoots $cfgNoAuto))[0] -eq (Expand-RgPath '%TEMP%\rg-x1'))) 'drives: autoRoots=false chỉ dùng workspaceRoots đã cấu hình'
    $realGet = ${function:Get-RgDrives}
    try {
        function Get-RgDrives { @([pscustomobject]@{ drive = 'C'; isSystem = $true }, [pscustomobject]@{ drive = 'Z'; isSystem = $false }) }
        $cfgAuto = [pscustomobject]@{ workspaceRoots = @('%TEMP%\rg-x2'); autoRootNames = @('Users', 'bad/name') }
        $ra = @(Get-RgWorkspaceRoots $cfgAuto)
        Assert ($ra.Count -eq 1) 'drives: ổ hệ thống không tự thêm root; ổ khác không có thư mục tên quen thì không thêm; tên chứa dấu / bị loại'
        function Get-RgDrives { @([pscustomobject]@{ drive = 'C'; isSystem = $true }, [pscustomobject]@{ drive = 'C'; isSystem = $false }) }
        $ra2 = @(Get-RgWorkspaceRoots ([pscustomobject]@{ workspaceRoots = @('%TEMP%\rg-x3'); autoRootNames = @('Users') }))
        Assert ((@($ra2 | Where-Object { $_ -ieq 'C:\Users' }).Count -eq 1)) 'drives: ổ không phải hệ thống tự thêm thư mục tên quen thuộc nếu tồn tại'
    } finally { Set-Item -Path Function:\Get-RgDrives -Value $realGet }

    # chạy thật + chạy thử trên fixture (AssumeStress)
    $oldTmp = Join-Path $tmp 'auto-old'; NewFile (Join-Path $oldTmp 'f.bin') 2048; Age $oldTmp 30
    $okProj = Join-Path $ws 'autoproj'; NewFile (Join-Path $okProj 'a.csproj') 10; NewFile (Join-Path $okProj 'obj\o.dll') 4096; Age (Join-Path $okProj 'obj') 30
    $keepProj = Join-Path $ws 'keepme'; NewFile (Join-Path $keepProj 'k.csproj') 10; NewFile (Join-Path $keepProj 'obj\o.dll') 4096; Age (Join-Path $keepProj 'obj') 30
    $pol = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; targetFreeGB = 1000; protectPaths = @($keepProj)
            categories = [pscustomobject]@{ 'temp-entry' = 'auto'; 'dotnet-artifact' = 'auto'; 'cache-aged' = 'ask'; 'node_modules' = 'keep'; 'process' = 'ask' } })
    Assert ((Save-RgPolicy $pol).updatedUtc -and (Get-RgPolicy).protectPaths[0] -eq $keepProj) 'policy: lưu và đọc lại'
    $cands = @(Get-RgCandidates)
    $dry = Invoke-RgAutoRun -Candidates $cands -Policy $pol -Real $false -AssumeStress $true -Trigger 'test'
    Assert ($dry.mode -eq 'dry-run' -and (Test-Path -LiteralPath $oldTmp) -and (Test-Path -LiteralPath (Join-Path $okProj 'obj')) -and @($dry.items | Where-Object { $_.outcome -eq 'would-run' }).Count -ge 2) 'auto dry-run: chọn mục nhưng không xoá gì'
    $real = Invoke-RgAutoRun -Candidates $cands -Policy $pol -Real $true -AssumeStress $true -Trigger 'test'
    Assert ($real.mode -eq 'on' -and -not (Test-Path -LiteralPath $oldTmp) -and -not (Test-Path -LiteralPath (Join-Path $okProj 'obj'))) 'auto on: xoá temp cũ + obj ngoài vùng bảo vệ'
    Assert (Test-Path -LiteralPath (Join-Path $keepProj 'obj\o.dll')) 'auto on: KHÔNG đụng thư mục trong vùng bảo vệ'
    $pl = Read-RgPlan $real.planId
    Assert ($pl.approval.approvedBy -eq 'policy' -and $pl.status -eq 'applied') 'auto on: đi qua plan -> approve(policy) -> apply'
    Assert ((Get-Content (Get-RgAutoLastPath) -Raw | ConvertFrom-Json).mode -eq 'on') 'auto: ghi auto-last.json'
    $arEv = @(Read-RgAutoRunEvents 1)
    $arDry = @($arEv | Where-Object { $_.data.mode -eq 'dry-run' })[-1]
    $arOn = @($arEv | Where-Object { $_.data.mode -eq 'on' })[-1]
    Assert ($arDry.data.byKind.'temp-entry'.items -ge 1 -and $arDry.data.byKind.'temp-entry'.bytes -ge 2048 -and $arDry.data.byKind.'dotnet-artifact'.items -ge 1 -and $null -ne $arDry.data.trigger -and $null -ne $arDry.data.freedBytes) 'auto-run: log có byKind {items, bytes} theo nhóm, các trường cũ giữ nguyên'
    Assert ($arOn.data.byKind.'temp-entry'.items -ge 1) 'auto-run: lượt chạy thật cũng ghi byKind'
    Assert ($null -eq (Get-RgJobState 'nope.json')) 'job: file không tồn tại -> null'
    Write-RgJobState 'zombie.progress.json' ([ordered]@{ pid = 999999; status = 'running'; message = '' })
    Assert ((Get-RgJobState 'zombie.progress.json').status -eq 'error') 'job: tiến trình đã chết mà vẫn "running" -> báo error'

    # rg-cleanup.ps1 (đường UI): chỉ nhận key, từ chối mục được bảo vệ / key lạ
    $cl1 = Join-Path $tmp 'ui-old'; NewFile (Join-Path $cl1 'f.bin') 1024; Age $cl1 30
    $keepProj2 = Join-Path $ws 'keepme\sub'; NewFile (Join-Path $keepProj2 's.csproj') 10; NewFile (Join-Path $keepProj2 'obj\o.dll') 100; Age (Join-Path $keepProj2 'obj') 30
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\rg-scan.ps1') -Mode candidates | Out-Null
    $cd = Get-Content (Join-Path $home_ 'state\scan-candidates.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $kTmp = @($cd.items | Where-Object { $_.path -eq $cl1 })[0].key
    $kProt = @($cd.items | Where-Object { $_.path -eq (Join-Path $keepProj2 'obj') })[0].key
    Assert ($kTmp -match '^[0-9a-f]{12}$' -and $kProt) 'scan candidates: có key ổn định cho từng mục'

    # ---- Biên lai ứng viên (P1): mỗi mục có đủ 5 trường; reason/risk cũ không đổi ----
    $rcFields = 'why', 'impact', 'regen', 'regenHint', 'riskLevel'
    $rcMissing = @($cd.items | Where-Object { $it = $_; @($rcFields | Where-Object { -not [string]$it.$_ }).Count -gt 0 })
    Assert ($cd.items.Count -gt 0 -and $rcMissing.Count -eq 0) 'receipt: scan-candidates.json có đủ 5 trường không rỗng cho mọi mục'
    Assert (@($cd.items | Where-Object { $_.regen -notin 'auto', 'rebuild', 'redownload', 'restore-zip', 'none' -or $_.riskLevel -notin 'low', 'medium', 'high' }).Count -eq 0) 'receipt: regen/riskLevel chỉ nhận giá trị trong hợp đồng'
    $rcTmp = @($cd.items | Where-Object { $_.path -eq $cl1 })[0]
    Assert ($rcTmp.regen -eq 'auto' -and $rcTmp.riskLevel -eq 'low' -and $rcTmp.why -match 'ngày' -and $rcTmp.reason -match '^temp entry untouched for \d+ days$' -and $rcTmp.risk -like 'low*') 'receipt: temp-entry => auto/low, why có số ngày, reason/risk tiếng Anh giữ nguyên'
    $recCands = @(Get-RgCandidates)
    $rcKinds = @{}
    foreach ($ci in $recCands) { if ($ci.action -ne 'report' -or $ci.kind -in 'app', 'vhdx', 'process') { if (-not $rcKinds.ContainsKey($ci.kind)) { $rcKinds[$ci.kind] = $ci } } }
    Assert ($rcKinds.ContainsKey('dotnet-artifact') -and $rcKinds['dotnet-artifact'].regen -eq 'rebuild' -and $rcKinds['dotnet-artifact'].riskLevel -eq 'low') 'receipt: dotnet-artifact => rebuild/low'
    $rcTbl = @{ 'temp-entry' = @('auto', 'low'); 'dotnet-artifact' = @('rebuild', 'low'); 'node_modules' = @('redownload', 'medium'); 'cache-aged' = @('redownload', 'low')
        'stale-repo' = @('restore-zip', 'medium'); 'large-item' = @('restore-zip', 'high'); 'process' = @('none', 'medium'); 'app' = @('none', 'high') }
    $rcBad = @()
    foreach ($ci in $recCands) {
        if ($ci.young -or $ci.action -eq 'report' -and $ci.kind -notin 'app', 'process') { continue }
        $exp = $rcTbl[[string]$ci.kind]
        if (-not $exp -or $ci.regen -ne $exp[0] -or $ci.riskLevel -ne $exp[1]) { $rcBad += "$($ci.kind):$($ci.regen)/$($ci.riskLevel)" }
    }
    Assert ($rcBad.Count -eq 0) "receipt: bảng ánh xạ kind -> regen/riskLevel đúng hợp đồng ($($rcBad -join ', '))"
    # mục young: rủi ro cao hơn bản thường (low -> medium, medium -> high)
    $baseTmp = [pscustomobject]@{ kind = 'temp-entry'; action = 'delete'; young = $false; ageDays = 30; newestWriteUtc = ''; sizeBytes = 1MB; path = 'C:\x\a'; name = ''; needsAdmin = $false }
    $youngTmp = [pscustomobject]@{ kind = 'temp-entry'; action = 'delete'; young = $true; ageDays = 1; newestWriteUtc = ''; sizeBytes = 1MB; path = 'C:\x\a'; name = ''; needsAdmin = $false }
    $baseNm = [pscustomobject]@{ kind = 'node_modules'; action = 'delete'; young = $false; ageDays = 0; newestWriteUtc = ''; sizeBytes = 1MB; path = 'C:\x\n'; name = ''; needsAdmin = $false }
    $youngNm = [pscustomobject]@{ kind = 'node_modules'; action = 'delete'; young = $true; ageDays = 2; newestWriteUtc = ''; sizeBytes = 1MB; path = 'C:\x\n'; name = ''; needsAdmin = $false }
    Assert ((Get-RgItemReceipt $baseTmp $cfg).riskLevel -eq 'low' -and (Get-RgItemReceipt $youngTmp $cfg).riskLevel -eq 'medium') 'receipt: temp-entry young tăng một bậc (low -> medium)'
    Assert ((Get-RgItemReceipt $baseNm $cfg).riskLevel -eq 'medium' -and (Get-RgItemReceipt $youngNm $cfg).riskLevel -eq 'high') 'receipt: node_modules young tăng một bậc (medium -> high)'
    Assert ((Get-RgItemReceipt $baseTmp $cfg).why -match '30 ngày') 'receipt: why nêu đúng số ngày không dùng'
    $unk = Get-RgItemReceipt ([pscustomobject]@{ kind = 'zzz'; action = 'report'; young = $false; ageDays = 0; newestWriteUtc = ''; sizeBytes = 0; path = ''; name = ''; needsAdmin = $false }) $cfg
    Assert ($unk.why -and $unk.impact -and $unk.regen -and $unk.regenHint -and $unk.riskLevel) 'receipt: kind lạ vẫn có đủ 5 trường (không lỗi)'
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\rg-cleanup.ps1') -Keys "$kTmp,$kProt,deadbeef0000,../../etc" | Out-Null
    $cr = Get-Content (Join-Path $home_ 'state\cleanup-last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (-not (Test-Path -LiteralPath $cl1) -and (Test-Path -LiteralPath (Join-Path $keepProj2 'obj'))) 'rg-cleanup: xoá mục được chọn, giữ mục trong vùng bảo vệ'
    Assert (@($cr.refused | Where-Object { $_.reason -match 'bảo vệ' }).Count -eq 1 -and @($cr.refused | Where-Object { $_.reason -match 'danh sách' }).Count -eq 1) 'rg-cleanup: từ chối mục bảo vệ + key lạ; key sai định dạng bị lọc'
    Assert ((Get-RgJobState 'cleanup.progress.json').status -eq 'done') 'rg-cleanup: ghi trạng thái job done'
    $cd2 = Get-Content (Join-Path $home_ 'state\scan-candidates.json') -Raw | ConvertFrom-Json
    Assert (@($cd2.items | Where-Object { $_.key -eq $kTmp }).Count -eq 0) 'rg-cleanup: mục đã xoá bị gỡ khỏi danh sách ứng viên'

    # ---- Remove-RgTree: xoá từng mục, junction chỉ gỡ link, mục bị giữ được báo cáo ----
    $rt1 = Join-Path $sandbox 'rt1'; NewFile (Join-Path $rt1 'a\b\ro.txt') 100; Set-ItemProperty (Join-Path $rt1 'a\b\ro.txt') IsReadOnly $true
    $rtTarget = Join-Path $sandbox 'rt-target'; NewFile (Join-Path $rtTarget 'keep.txt') 10
    cmd /c mklink /J (Join-Path $rt1 'junc') $rtTarget | Out-Null
    $rr = Remove-RgTree $rt1
    Assert ($rr.removed -and -not (Test-Path $rt1) -and (Test-Path (Join-Path $rtTarget 'keep.txt'))) 'Remove-RgTree: xoá cả file read-only, gỡ junction mà không đụng đích'
    $rt2 = Join-Path $sandbox 'rt2'; NewFile (Join-Path $rt2 'ok.txt') 10; NewFile (Join-Path $rt2 'held.txt') 10
    $held = [IO.File]::Open((Join-Path $rt2 'held.txt'), 'Open', 'ReadWrite', 'None')
    $rr2 = Remove-RgTree $rt2
    $held.Dispose()
    Assert (-not $rr2.removed -and $rr2.failed -eq 1 -and $rr2.count -eq 1 -and -not (Test-Path (Join-Path $rt2 'ok.txt'))) 'Remove-RgTree: mục bị giữ được báo cáo, phần còn lại vẫn xoá'

    # ---- Dọn bằng quyền admin: kiểm tra độc lập, không tin đường dẫn trong state ----
    $guid = [guid]::NewGuid().ToString().ToUpper()
    $ea = Join-Path $tmp $guid; NewFile (Join-Path $ea 'lock') 0; NewFile (Join-Path $ea 'x\f.bin') 50; Age $ea 20
    $eaNew = Join-Path $tmp ([guid]::NewGuid().ToString().ToUpper() + '.scratch'); NewFile (Join-Path $eaNew 'lock') 0
    $eaName = Join-Path $tmp 'not-a-guid'; NewFile (Join-Path $eaName 'f') 5; Age $eaName 20
    $eaJ = Join-Path $tmp ([guid]::NewGuid().ToString().ToUpper()); cmd /c mklink /J $eaJ $rtTarget | Out-Null
    Assert ($null -eq (Get-RgElevatedDeleteBlocker $ea $cfg $tmp)) 'elevated: thư mục GUID đủ tuổi trong Temp được chấp nhận'
    Assert ((Get-RgElevatedDeleteBlocker $eaNew $cfg $tmp) -match 'last') 'elevated: thư mục GUID còn mới bị chặn'
    Assert ((Get-RgElevatedDeleteBlocker $eaName $cfg $tmp) -match 'GUID') 'elevated: tên không phải GUID bị chặn'
    Assert ((Get-RgElevatedDeleteBlocker (Join-Path $ea 'x') $cfg $tmp) -match 'direct child|GUID') 'elevated: thư mục con lồng sâu bị chặn'
    Assert ((Get-RgElevatedDeleteBlocker $eaJ $cfg $tmp) -match 'junction') 'elevated: junction bị chặn'
    Assert ((Get-RgElevatedDeleteBlocker $ea $cfg (Join-Path $sandbox 'other')) -match 'direct child') 'elevated: sai thư mục Temp bị chặn'
    # state giả: 1 mục hợp lệ + 1 mục không gắn needsAdmin + 1 mục bị sửa đường dẫn sang thư mục tên thường
    $kOk = 'aaaaaaaaaaaa'; $kNo = 'bbbbbbbbbbbb'; $kTamper = 'cccccccccccc'
    $fake = [ordered]@{ finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); seconds = 0; items = @(
            [ordered]@{ key = $kOk; kind = 'temp-entry'; action = 'report'; path = $ea; needsAdmin = $true },
            [ordered]@{ key = $kNo; kind = 'temp-entry'; action = 'delete'; path = $eaNew; needsAdmin = $false },
            [ordered]@{ key = $kTamper; kind = 'temp-entry'; action = 'report'; path = $eaName; needsAdmin = $true }) }
    Set-Content (Join-Path $home_ 'state\scan-candidates.json') (ConvertTo-Json $fake -Depth 6) -Encoding UTF8
    $er = Invoke-RgElevatedClean -Keys @($kOk, $kNo, $kTamper, 'zz', '../x') -TempRoot $tmp
    Assert (-not (Test-Path $ea)) 'elevated: mục hợp lệ bị xoá'
    Assert ((Test-Path $eaNew) -and (Test-Path $eaName)) 'elevated: mục không gắn needsAdmin và mục bị đổi sang đường dẫn lạ còn nguyên'
    Assert (@($er.refused).Count -eq 1 -and @($er.results | Where-Object { $_.outcome -eq 'skipped' }).Count -eq 1 -and @($er.results | Where-Object { $_.outcome -eq 'done' }).Count -eq 1) 'elevated: kết quả ghi đúng done/skipped/refused'
    $elast = Get-Content (Join-Path $home_ 'state\cleanup-last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($elast.elevated -eq $true) 'elevated: cleanup-last.json đánh dấu elevated'
    # ứng viên do chính tài khoản hiện tại sở hữu không bị gắn needsAdmin
    $own = Join-Path $tmp ([guid]::NewGuid().ToString().ToUpper()); NewFile (Join-Path $own 'f') 5; Age $own 40
    $cands = @(Get-RgCandidates)
    $ownItem = @($cands | Where-Object { $_.path -eq $own })[0]
    Assert ($ownItem -and $ownItem.action -eq 'delete' -and -not $ownItem.needsAdmin) 'candidates: thư mục temp của chính user vẫn là mục xoá được'

    # ---- Mục dung lượng lớn + nén zip tại chỗ ----
    function G { $e = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & git @args 2>&1 | Out-Null; $ErrorActionPreference = $e }
    $big = Join-Path $dl 'bigproj'
    NewFile (Join-Path $big 'a\data1.bin') 3000; NewFile (Join-Path $big 'b\c\data2.bin') 2000
    $rnd = New-Object byte[] 4096; (New-Object Random 7).NextBytes($rnd); [IO.File]::WriteAllBytes((Join-Path $big 'a\rand.bin'), $rnd)
    [void][IO.Directory]::CreateDirectory((Join-Path $big 'emptydir'))
    $h0 = (Get-FileHash (Join-Path $big 'a\rand.bin')).Hash
    Age $big 90
    $iso = Join-Path $dl 'old.iso'; [IO.File]::WriteAllBytes($iso, $rnd); $hIso = (Get-FileHash $iso).Hash; Age $iso 90   # băm trước: đọc file làm đổi LastAccessTime
    $fresh = Join-Path $dl 'fresh.iso'; NewFile $fresh 100
    $c2 = @(Get-RgCandidates)
    $cBig = @($c2 | Where-Object { $_.path -eq $big })[0]
    Assert ($cBig -and $cBig.kind -eq 'large-item' -and $cBig.action -eq 'delete') 'large-item: mục lớn lâu không đụng thành ứng viên xoá'
    Assert (-not (@($c2 | Where-Object { $_.path -eq $fresh }).Count)) 'large-item: mục mới dùng không là ứng viên'
    Assert ((Test-RgArchivable 'large-item') -and (Test-RgArchivable 'stale-repo') -and -not (Test-RgArchivable 'node_modules')) 'archive: chỉ repo cũ và mục lớn nén zip được'
    $pz = New-RgPlan -Items @(
        (New-RgItem -Kind 'large-item' -Action delete -Level 2 -Path $big -SizeBytes 9000 -AgeDays 90 -Archive $true),
        (New-RgItem -Kind 'large-item' -Action delete -Level 2 -Path $iso -SizeBytes 4096 -AgeDays 90 -Archive $true))
    [void](Set-RgPlanApproval -PlanId $pz.planId -ItemIds @(1, 2) -By 'test-human')
    $rz = Invoke-RgApply -PlanId $pz.planId
    Assert (@($rz.results | Where-Object { $_.outcome -eq 'done' }).Count -eq 2) 'archive: cả thư mục và file đều "done"'
    Assert (-not (Test-Path $big) -and -not (Test-Path $iso) -and (Test-Path (Join-Path $dl 'bigproj.zip')) -and (Test-Path (Join-Path $dl 'old.iso.zip'))) 'archive: bản gốc đã xoá, zip nằm cạnh vị trí cũ'
    Assert (@(Get-ChildItem $dl -Filter '*.partial').Count -eq 0) 'archive: không để lại file .partial'
    $recs = @(Read-RgArchives)
    Assert ($recs.Count -eq 2 -and @($recs | Where-Object { $_.original -eq $big }).Count -eq 1) 'archive: đã ghi sổ archives.json'
    $rBig = @($recs | Where-Object { $_.original -eq $big })[0]; $rIso = @($recs | Where-Object { $_.original -eq $iso })[0]
    [void](Restore-RgArchive $rBig.id); [void](Restore-RgArchive $rIso.id)
    Assert ((Get-FileHash (Join-Path $big 'a\rand.bin')).Hash -eq $h0 -and (Test-Path (Join-Path $big 'emptydir')) -and (Test-Path (Join-Path $big 'b\c\data2.bin'))) 'restore: thư mục khôi phục đủ nội dung, hash khớp, giữ thư mục rỗng'
    Assert ((Get-FileHash $iso).Hash -eq $hIso) 'restore: file đơn khôi phục đúng hash'
    $thrown = $false; try { [void](Restore-RgArchive $rBig.id) } catch { $thrown = $true }
    Assert $thrown 'restore: không ghi đè khi vị trí cũ đã có dữ liệu'
    # zip lỗi (junction bên trong) => từ chối, bản gốc nguyên vẹn
    $jd = Join-Path $dl 'withjunction'; NewFile (Join-Path $jd 'f.bin') 10
    cmd /c mklink /J (Join-Path $jd 'j') $rtTarget | Out-Null
    $arj = New-RgArchive $jd
    Assert (-not $arj.ok -and (Test-Path (Join-Path $jd 'f.bin')) -and @(Get-ChildItem $dl -Filter 'withjunction*.zip*').Count -eq 0) 'archive: có junction bên trong => từ chối, không để zip dang dở'
    # file đang bị khoá => huỷ, giữ nguyên
    $lk = Join-Path $dl 'locked'; NewFile (Join-Path $lk 'busy.bin') 100
    $busy = [IO.File]::Open((Join-Path $lk 'busy.bin'), 'Open', 'ReadWrite', 'None')
    $arl = New-RgArchive $lk
    $busy.Dispose()
    Assert (-not $arl.ok -and (Test-Path (Join-Path $lk 'busy.bin')) -and @(Get-ChildItem $dl -Filter 'locked*.zip*').Count -eq 0) 'archive: file đang bị khoá => huỷ, bản gốc còn nguyên'
    # đường dẫn không nằm trực tiếp trong root large-item bị chặn
    $deep = Join-Path $big 'a'; Age $big 90
    Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'large-item' -Action delete -Level 2 -Path $deep) $cfg) -match 'direct child') 'large-item: không phải con trực tiếp của root => bị chặn'

    # ---- Repo cũ: chỉ đề xuất xoá khi mọi thứ đã có trên remote ----
    if (Get-RgGitExe) {
        $remote = Join-Path $sandbox 'remote.git'; G init --bare -q $remote
        function NewRepo([string]$Path, [bool]$Push) {
            G init -q $Path; NewFile (Join-Path $Path 'src\a.cs') 200
            G -C $Path add -A; G -C $Path -c user.name=t -c user.email=t@t commit -q -m init
            if ($Push) { G -C $Path remote add origin $remote; G -C $Path push -q -u origin HEAD }
        }
        $rOk = Join-Path $ws 'staleok'; NewRepo $rOk $true; Age $rOk 120
        $rLocal = Join-Path $ws 'stalelocal'; NewRepo $rLocal $false; Age $rLocal 120
        $rDirty = Join-Path $ws 'staledirty'; NewRepo $rDirty $true; NewFile (Join-Path $rDirty 'untracked.txt') 5; Age $rDirty 120
        $rFresh = Join-Path $ws 'freshrepo'; NewRepo $rFresh $true
        $c3 = @(Get-RgCandidates)
        $sOk = @($c3 | Where-Object { $_.path -eq $rOk })[0]; $sLocal = @($c3 | Where-Object { $_.path -eq $rLocal })[0]; $sDirty = @($c3 | Where-Object { $_.path -eq $rDirty })[0]
        Assert ($sOk.kind -eq 'stale-repo' -and $sOk.action -eq 'delete') 'stale-repo: repo cũ, sạch, đã push => ứng viên xoá'
        Assert ($sLocal.action -eq 'report' -and $sLocal.reason -match 'not on any remote') 'stale-repo: có commit chưa lên remote => chỉ báo cáo'
        Assert ($sDirty.action -eq 'report' -and $sDirty.reason -match 'uncommitted') 'stale-repo: có file chưa commit => chỉ báo cáo'
        Assert (-not (@($c3 | Where-Object { $_.path -eq $rFresh }).Count)) 'stale-repo: repo mới sửa không là ứng viên'
        Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'stale-repo' -Action delete -Level 2 -Path $rDirty) $cfg) -match 'uncommitted') 'stale-repo: blocker lúc apply chặn repo bẩn dù đã bị chọn'
        Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'stale-repo' -Action delete -Level 2 -Path $rFresh) $cfg) -match 'modified within') 'stale-repo: blocker chặn repo mới sửa'
        $ps = New-RgPlan -Items @((New-RgItem -Kind 'stale-repo' -Action delete -Level 2 -Path $rOk -SizeBytes 1000 -AgeDays 120 -Archive $true))
        [void](Set-RgPlanApproval -PlanId $ps.planId -ItemIds @(1) -By 'test-human')
        $rs = Invoke-RgApply -PlanId $ps.planId
        Assert ($rs.results[0].outcome -eq 'done' -and -not (Test-Path $rOk) -and (Test-Path (Join-Path $ws 'staleok.zip'))) 'stale-repo: nén zip rồi xoá repo (kể cả .git chỉ đọc)'
        $rec = @(Read-RgArchives | Where-Object { $_.original -eq $rOk })[0]
        [void](Restore-RgArchive $rec.id)
        Assert (Test-Path (Join-Path $rOk '.git') -PathType Container) 'stale-repo: giải nén khôi phục được cả .git'
    } else { Write-Host '  SKIP  stale-repo (không có git)' }

    # ---- Ứng dụng: chỉ báo cáo, bỏ qua mục Windows ----
    NewFile (Join-Path $apps 'OldApp\app.dll') 1000; Age (Join-Path $apps 'OldApp') 300
    NewFile (Join-Path $apps 'Windows Kit\k.dll') 1000; Age (Join-Path $apps 'Windows Kit') 300
    NewFile (Join-Path $apps 'ActiveApp\a.dll') 1000
    $c4 = @(Get-RgCandidates)
    $aOld = @($c4 | Where-Object { $_.path -eq (Join-Path $apps 'OldApp') })[0]
    Assert ($aOld.kind -eq 'app' -and $aOld.action -eq 'report') 'app: ứng dụng lâu không ghi file => chỉ báo cáo'
    Assert (-not (@($c4 | Where-Object { $_.path -like (Join-Path $apps 'Windows Kit*') -or $_.path -eq (Join-Path $apps 'ActiveApp') }).Count)) 'app: bỏ qua mục Windows và app đang hoạt động'
    Assert ((Get-RgDeleteBlocker (New-RgItem -Kind 'app' -Action delete -Level 3 -Path (Join-Path $apps 'OldApp')) $cfg) -match 'not deletable') 'app: không bao giờ xoá được (blocker)'

    # ---- Agent (P19): payload mang kế hoạch tất định + nhóm cần xem lại ----
    Write-Host "`n[agent] payload có advice.steps + review.keys (P19)"
    . (Join-Path $root 'scripts\rg-agent.ps1')   # chỉ nạp hàm (rg-agent tự return khi bị dot-source)
    $apl = New-RgAgentPayload
    Assert ($apl.Contains('advice') -and $apl.advice.Contains('steps') -and $apl.Contains('review') -and $apl.review.Contains('keys')) 'agent: payload có advice.steps và review.keys'
    $aKeys = @($apl.cleanupCandidates | ForEach-Object { $_.key })
    Assert (@($apl.review.keys | Where-Object { $aKeys -notcontains $_ }).Count -eq 0) 'agent: mọi key trong review.keys đều nằm trong cleanupCandidates (để key agent trả về còn hợp lệ)'
    Assert (@($apl.advice.steps | Where-Object { -not $_.id -or -not $_.kind -or $null -eq $_.bytes -or -not $_.riskLevel }).Count -eq 0) 'agent: mỗi bước advice trong payload có id/kind/bytes/riskLevel'
    Assert ((Get-RgAgentPrompt '{}') -match 'review\.keys' -and (Get-RgAgentPrompt '{}') -match 'nên làm gì trước') 'agent: prompt yêu cầu đánh giá review.keys trước và summary trả lời "nên làm gì trước"'

    # ---- Scanner v2 (P9): cây thư mục giả, -RootOverride/-OutDir. Số mong đợi tính từ chính các file đã tạo; đã đối chiếu với bản cũ trên ổ C thật
    #      (cùng số file/byte từng nhóm ở các nhóm không đổi giữa hai lượt: system-windows 39.854.473.064 B/181.345 file, programs 20.356.088.081 B/50.182 file). ----
    Write-Host "`n[scanner] quét v2: tổng khớp, junction, vùng quét, cây thư mục (P9)"
    $sr = Join-Path $sandbox 'scanroot'; $so = Join-Path $sandbox 'scanout'
    $script:scanFiles = 0; $script:scanBytes = 0L
    function SF([string]$Rel, [int]$Bytes) { NewFile (Join-Path $sr $Rel) $Bytes; $script:scanFiles++; $script:scanBytes += $Bytes }
    SF 'Windows\a.dll' 1000; SF 'Windows\sub\b.dll' 2000; SF 'Program Files\App\p.exe' 3000; SF 'ProgramData\x\y.dat' 500
    SF 'Users\me\Documents\doc.txt' 700; SF 'Users\me\Downloads\d.zip' 1100; SF 'Users\me\AppData\Local\Temp\t1.tmp' 400; SF 'Users\me\AppData\Local\Temp\sub\t2.tmp' 600
    SF 'Users\me\.nuget\pkg\n.nupkg' 900; SF 'Users\me\file-in-profile.txt' 50; SF 'Users\me\deep\a\b\c\d\e\f\g\x.bin' 1000
    SF 'Users\other\o.dat' 800; SF 'Users\other\Docs\o2.dat' 200; SF 'pagefile.sys' 4000; SF 'loose\l.bin' 300
    $junc = Join-Path $sr 'junc-to-windows'
    cmd /c mklink /J "$junc" (Join-Path $sr 'Windows') | Out-Null
    function RunScan([string[]]$ScanArgs, [string]$ScanDrive = 'C') {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\rg-scan.ps1') -Mode breakdown -Drive $ScanDrive -RootOverride $sr -OutDir $so @ScanArgs *> $null
        $c = $LASTEXITCODE; $ErrorActionPreference = $old; return $c
    }
    function ReadScanJson([string]$Name) { ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $so $Name) -Raw -Encoding UTF8) }
    function IsoOf($V) { if ($V -is [datetime]) { return $V.ToUniversalTime().ToString('o') }; return [string]$V }   # PS 7 đọc chuỗi ISO thành DateTime
    function CatOf($B, [string]$Cat) { @($B.categories | Where-Object { $_.cat -eq $Cat })[0] }
    function TreeViolations($N) { $s = 0L; $v = 0; foreach ($k in @($N.children)) { $s += [long]$k.bytes; $v += (TreeViolations $k) }; if ($s -gt [long]$N.bytes) { $v++ }; return $v }
    function TreeFind($N, [string]$Like) { if ([string]$N.path -like $Like) { return $N }; foreach ($k in @($N.children)) { $f = TreeFind $k $Like; if ($f) { return $f } }; return $null }

    Assert ((RunScan @('-Scope', 'full')) -eq 0) 'scanner: quét full trên cây giả thoát 0'
    $bf = ReadScanJson 'scan-breakdown-C.json'
    Assert ($bf.files -eq $script:scanFiles -and $bf.scannedBytes -eq $script:scanBytes) ("scanner: tổng file/byte bằng đúng số đã tạo ({0} file, {1} B), junction không bị đi vào" -f $script:scanFiles, $script:scanBytes)
    Assert ($bf.scope -eq 'full' -and $bf.errors -eq 0 -and $bf.skippedDirs -eq 0 -and $bf.threads -ge 1 -and $bf.threads -le 8) 'scanner: scope=full, không lỗi, không bỏ qua thư mục nào, số luồng trong 1..8'
    Assert ((CatOf $bf 'system-windows').bytes -eq 3000 -and (CatOf $bf 'programs').bytes -eq 3000 -and (CatOf $bf 'program-data').bytes -eq 500) 'scanner: nhóm hệ thống đúng byte (junction không nhân đôi Windows)'
    Assert ((CatOf $bf 'documents').bytes -eq 700 -and (CatOf $bf 'downloads').bytes -eq 1100 -and (CatOf $bf 'temp').bytes -eq 1000 -and (CatOf $bf 'dev-cache').bytes -eq 900) 'scanner: nhóm tài liệu/downloads/temp/dev-cache đúng byte'
    Assert ((CatOf $bf 'user-other').bytes -eq 2050 -and (CatOf $bf 'system-files').bytes -eq 4000 -and (CatOf $bf 'other').bytes -eq 300) 'scanner: user-other (hồ sơ khác + phần còn lại của mình), system-files, other đúng byte'
    Assert ((CatOf $bf 'system-windows').zone -eq 'fixed' -and (CatOf $bf 'system-windows').actionable -eq 'fixed' -and (CatOf $bf 'temp').zone -eq 'hot' -and (CatOf $bf 'temp').actionable -eq 'cleanable' -and (CatOf $bf 'documents').zone -eq 'warm' -and (CatOf $bf 'documents').actionable -eq 'review') 'scanner: mỗi nhóm có zone/actionable (fixed|warm|hot, fixed|review|cleanable)'
    Assert (-not @($bf.categories | Where-Object { $null -eq $_.scannedUtc -or $null -eq $_.carried }).Count -and -not (@($bf.categories | Where-Object { $_.carried }).Count)) 'scanner: full -> mọi nhóm có scannedUtc, không nhóm nào carried'
    $fx = ReadScanJson 'scan-fixed-C.json'
    $fxBytes = 0L; foreach ($e in @($fx.entries)) { $fxBytes += [long]$e.bytes }
    Assert ($fxBytes -eq 7500) 'scanner: scan-fixed ghi đúng phần vùng cố định (Windows 3000 + Program Files 3000 + ProgramData 500 + hồ sơ khác 1000)'
    $tf = ReadScanJson 'scan-tree-C.json'
    Assert ($tf.drive -eq 'C' -and $tf.scope -eq 'full' -and $tf.root.bytes -eq $script:scanBytes -and (TreeViolations $tf.root) -eq 0) 'scanner: file cây có gốc = tổng đã quét và tổng con <= cha ở mọi nút'
    $dNode = TreeFind $tf.root '*\Users\me\deep\a\b\c\d'
    Assert ($dNode -and $dNode.bytes -eq 1000 -and -not (TreeFind $tf.root '*\deep\a\b\c\d\e')) 'scanner: cây dừng ở 5 cấp dưới tiền tố rule (cấp sâu hơn gộp vào nút cấp 5)'
    $wNode = TreeFind $tf.root '*\Windows'
    Assert ($wNode -and $wNode.zone -eq 'fixed' -and $wNode.bytes -eq 3000) 'scanner: nút Windows trong cây có zone = fixed'
    $prog = Get-Content -LiteralPath (Join-Path $so 'scan-breakdown.progress.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($prog.status -eq 'done' -and $prog.scope -eq 'full' -and @($prog.cats).Count -ge 5 -and $null -ne @($prog.cats)[0].bytes) 'scanner: tiến độ có cats [{cat, bytes}] để UI vẽ dần'

    # focus: bỏ qua vùng fixed, mượn số từ lượt full; không thấy file mới ở vùng fixed nhưng thấy file mới ở vùng hot
    SF 'Windows\late.dll' 5000   # file mới trong vùng fixed (focus không được thấy)
    SF 'Users\me\AppData\Local\Temp\t3.tmp' 100
    Assert ((RunScan @('-Scope', 'focus')) -eq 0) 'scanner: quét focus thoát 0'
    $bo = ReadScanJson 'scan-breakdown-C.json'
    Assert ($bo.scope -eq 'focus' -and $bo.skippedDirs -eq 4 -and $bo.carriedBytes -eq 7500 -and $bo.freshBytes -eq ($bo.scannedBytes - 7500)) 'scanner: focus bỏ qua 4 thư mục fixed (Windows, Program Files, ProgramData, hồ sơ khác) và mượn 7500 B'
    Assert ($bo.files -lt ($script:scanFiles)) 'scanner: focus liệt kê ít file hơn (không vào thư mục fixed)'
    $cw = CatOf $bo 'system-windows'
    Assert ($cw.bytes -eq 3000 -and $cw.carried -eq $true -and (IsoOf $cw.scannedUtc) -eq (IsoOf $bf.finishedUtc)) 'scanner: focus -> system-windows lấy từ lượt full (3000 B, carried, scannedUtc của lượt full), không thấy late.dll'
    Assert ((CatOf $bo 'temp').bytes -eq 1100 -and (CatOf $bo 'temp').carried -eq $false) 'scanner: focus thấy file mới ở vùng hot (temp 1100 B)'
    $uo = CatOf $bo 'user-other'
    Assert ($uo.bytes -eq 2050 -and $uo.carriedBytes -eq 1000 -and $uo.carried -eq $true) 'scanner: user-other trộn quét mới + mượn (hồ sơ người khác 1000 B)'
    $to = ReadScanJson 'scan-tree-C.json'
    $expRoot = $script:scanBytes - 5000   # late.dll không được thấy ở focus
    Assert ($to.scope -eq 'focus' -and $to.root.bytes -eq $expRoot -and (TreeViolations $to.root) -eq 0) 'scanner: cây focus giữ nút fixed từ lượt full (gốc = fresh + mượn), tổng con <= cha'
    $ow = TreeFind $to.root '*\Windows'
    Assert ($ow -and $ow.bytes -eq 3000 -and $ow.zone -eq 'fixed') 'scanner: cây focus có nút Windows (fixed) ghép từ cây cũ'
    $ou = TreeFind $to.root '*\Users\other'
    Assert ($ou -and $ou.bytes -eq 1000) 'scanner: cây focus ghép cả hồ sơ người khác dưới Users'
    # full lại thấy file mới ở vùng fixed
    Assert ((RunScan @('-Scope', 'full')) -eq 0 -and (CatOf (ReadScanJson 'scan-breakdown-C.json') 'system-windows').bytes -eq 8000) 'scanner: quét full lại thấy late.dll (system-windows 8000 B)'
    # focus khi chưa có phần fixed: không mượn gì, nhóm fixed vắng mặt
    Remove-Item -LiteralPath (Join-Path $so 'scan-fixed-C.json'), (Join-Path $so 'scan-tree-C.json') -Force
    Assert ((RunScan @('-Scope', 'focus')) -eq 0) 'scanner: focus khi chưa có lượt full thoát 0'
    $bn = ReadScanJson 'scan-breakdown-C.json'
    Assert ($bn.carriedBytes -eq 0 -and -not (CatOf $bn 'system-windows') -and -not (CatOf $bn 'programs')) 'scanner: focus lần đầu -> không có số fixed (UI hiện khối "chưa quét chi tiết")'
    Assert ((RunScan @() 'ZZ') -ne 0)'scanner: tên ổ sai -> thoát khác 0'

    # ---- Quét nền tự làm mới (P10): quyết định thuần Test-RgScanDue ----
    Write-Host "`n[scandue] quét nền tự làm mới: quyết định thuần (P10)"
    $n0 = Get-Date
    function DueCase([double]$Refresh, [bool]$Running, [double[]]$Cpu, $Last, $Drives, $Cand) { Test-RgScanDue -Now $n0 -JobRunning $Running -CpuSamples $Cpu -LastAutoStart $Last -RefreshHours $Refresh -Drives $Drives -CandidatesUtc $Cand }
    function DrvInfo([string]$L, $FocusAgeH, $FullAgeD) { [pscustomobject]@{ drive = $L; focusUtc = $(if ($null -eq $FocusAgeH) { $null } else { $n0.AddHours(-[double]$FocusAgeH) }); fullUtc = $(if ($null -eq $FullAgeD) { $null } else { $n0.AddDays(-[double]$FullAgeD) }) } }
    $cOk = @(10, 20, 30); $candFresh = $n0.AddHours(-1)
    $r = DueCase 0 $false $cOk $null @(DrvInfo 'C' 50 1) $null
    Assert (-not $r.due -and $r.because -match 'tắt') 'scandue: autoRefreshHours = 0 -> tắt hẳn dù kết quả rất cũ'
    Assert (-not (DueCase 6 $true $cOk $null @(DrvInfo 'C' 50 1) $null).due) 'scandue: đang có job nền chạy -> không quét'
    Assert (-not (DueCase 6 $false @(10, 20) $null @(DrvInfo 'C' 50 1) $null).due) 'scandue: chưa đủ 3 mẫu CPU -> chờ'
    Assert (-not (DueCase 6 $false @(10, 60, 60, 60) $null @(DrvInfo 'C' 50 1) $null).due) 'scandue: CPU trung bình 3 mẫu cuối 60% -> máy bận, không quét'
    Assert ((DueCase 6 $false @(90, 90, 20, 30, 40) $null @(DrvInfo 'C' 50 1) $candFresh).due) 'scandue: chỉ tính 3 mẫu cuối (30% trung bình) -> được quét'
    Assert (-not (DueCase 6 $false $cOk $n0.AddMinutes(-5) @(DrvInfo 'C' 50 1) $null).due) 'scandue: vừa tự quét cách đây 5 phút -> chờ đủ 10 phút'
    Assert ((DueCase 6 $false $cOk $n0.AddMinutes(-11) @(DrvInfo 'C' 50 1) $candFresh).due) 'scandue: cách lần trước 11 phút -> được quét'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' 7 1) $candFresh
    Assert ($r.due -and $r.kind -eq 'breakdown' -and $r.drive -eq 'C' -and $r.scope -eq 'focus') 'scandue: ổ C cũ 7 giờ, lượt full 1 ngày -> quét focus ổ C'
    Assert (-not (DueCase 6 $false $cOk $null @(DrvInfo 'C' 5 1) $candFresh).due) 'scandue: ổ C cũ 5 giờ (< 6) -> chưa cần'
    Assert ((DueCase 6 $false $cOk $null @(DrvInfo 'C' 7 8) $candFresh).scope -eq 'full') 'scandue: lượt full cũ 8 ngày -> quét full'
    Assert ((DueCase 6 $false $cOk $null @(DrvInfo 'C' 7 $null) $candFresh).scope -eq 'full') 'scandue: chưa từng quét full -> quét full'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' $null $null) $candFresh
    Assert ($r.due -and $r.because -match 'chưa có') 'scandue: ổ chưa có kết quả nào -> quét, nêu lý do chưa có'
    $r = DueCase 6 $false $cOk $null @((DrvInfo 'C' 7 1), (DrvInfo 'D' 20 1)) $candFresh
    Assert ($r.drive -eq 'D') 'scandue: nhiều ổ cùng cũ -> chọn ổ cũ nhất (mỗi lần một ổ)'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' 1 1) $n0.AddHours(-10)
    Assert ($r.due -and $r.kind -eq 'candidates') 'scandue: ổ còn mới, quét ứng viên cũ 10 giờ -> quét ứng viên'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' 20 1) $n0.AddHours(-10)
    Assert ($r.kind -eq 'breakdown') 'scandue: ổ (20 giờ) cũ hơn ứng viên (10 giờ) -> quét ổ trước'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' 20 1) $n0.AddHours(-30)
    Assert ($r.kind -eq 'candidates') 'scandue: ứng viên (30 giờ) cũ hơn ổ (20 giờ) -> quét ứng viên trước'
    $r = DueCase 6 $false $cOk $null @(DrvInfo 'C' 1 1) $candFresh
    Assert (-not $r.due -and $r.because -match 'còn mới') 'scandue: mọi thứ còn mới -> không quét'
    Assert ((Get-RgScanRefreshHours ([pscustomobject]@{})) -eq 6 -and (Get-RgScanRefreshHours ([pscustomobject]@{ scan = [pscustomobject]@{ autoRefreshHours = 0 } })) -eq 0 -and (Get-RgScanRefreshHours ([pscustomobject]@{ scan = [pscustomobject]@{ autoRefreshHours = -3 } })) -eq 0 -and (Get-RgScanRefreshHours ([pscustomobject]@{ scan = [pscustomobject]@{ autoRefreshHours = 2.5 } })) -eq 2.5) 'scandue: Get-RgScanRefreshHours: thiếu khoá = 6, âm = 0, đọc đúng giá trị'
    Assert ((Get-RgScanRefreshHours $cfg) -eq 0) 'scandue: config của test ép autoRefreshHours = 0 (server test không tự quét ổ thật)'

    # ---- API end-to-end: khởi động server THẬT trong sandbox (home tạm, cổng ngẫu nhiên), kiểm cổng X-RG-Client và các route mới ----
    Write-Host "`n[api] server thật trong sandbox"
    [void](Save-RgPolicy (ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'off' })))   # server không được tự dọn trong lúc test
    $lsn = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $lsn.Start(); $apiPort = ([Net.IPEndPoint]$lsn.LocalEndpoint).Port; $lsn.Stop()
    $apiBase = "http://127.0.0.1:$apiPort"
    $srvProc = Start-Process $hostExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $root 'scripts\rg-server.ps1') + '"'), '-Port', $apiPort, '-NoOpen', '-NoToast' `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $sandbox 'srv.out') -RedirectStandardError (Join-Path $sandbox 'srv.err')
    $hdr = @{ 'X-RG-Client' = 'ui' }
    function Api([string]$Method, [string]$Path, $Body = $null, [bool]$WithClientHeader = $true) {   # trả { code; json }
        $o = @{ UseBasicParsing = $true; Uri = "$apiBase$Path"; Method = $Method; TimeoutSec = 30 }
        if ($WithClientHeader) { $o.Headers = $hdr }
        if ($null -ne $Body) { $o.Body = (ConvertTo-Json $Body -Depth 6); $o.ContentType = 'application/json' }
        try { $r = Invoke-WebRequest @o; return [pscustomobject]@{ code = [int]$r.StatusCode; json = $(try { ConvertFrom-Json $r.Content } catch { $null }) } }
        catch { $c = 0; if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }; return [pscustomobject]@{ code = $c; json = $(try { ConvertFrom-Json $_.ErrorDetails.Message } catch { $null }) } }
    }
    try {
        $up = $false
        for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; if ($srvProc.HasExited) { break }; $up = ((Api 'GET' '/api/setup').code -eq 200) }
        Assert $up 'api: server khởi động và trả /api/setup'
        $liveOk = $false
        for ($i = 0; $i -lt 60 -and -not $liveOk; $i++) { $liveOk = ((Api 'GET' '/api/insight').code -eq 200); if (-not $liveOk) { Start-Sleep -Milliseconds 500 } }
        Assert $liveOk 'api: có số liệu live sau vài giây (/api/insight 200)'

        Assert ((Api 'POST' '/api/setup' @{ firstRunDone = $true } $false).code -eq 403) 'api: POST /api/setup thiếu X-RG-Client -> 403'
        Assert ((Api 'POST' '/api/auto/preview' @{ policy = @{ mode = 'dry-run' } } $false).code -eq 403) 'api: POST /api/auto/preview thiếu X-RG-Client -> 403'
        Assert ((Api 'POST' '/api/process/priority' @{ pid = $PID; start = 'x'; level = 'below' } $false).code -eq 403) 'api: POST /api/process/priority thiếu X-RG-Client -> 403'
        $g0 = Api 'GET' '/api/setup'
        Assert ($g0.json.firstRun -eq $true -and $null -ne $g0.json.autostart -and $null -ne $g0.json.shortcut -and $null -ne $g0.json.pinConfigured -and $g0.json.mode -eq 'off') 'api: GET /api/setup -> { autostart, shortcut, pinConfigured, mode, firstRun }'
        $p1 = Api 'POST' '/api/setup' @{ firstRunDone = $true }
        Assert ($p1.code -eq 200 -and $p1.json.ok -and (Api 'GET' '/api/setup').json.firstRun -eq $false) 'api: POST firstRunDone -> firstRun = false'
        Assert ((Api 'POST' '/api/setup' @{ autostart = 'maybe' }).code -eq 400) 'api: POST /api/setup giá trị sai kiểu -> 400'

        $ins = Api 'GET' '/api/insight'
        Assert (@($ins.json.readiness).Count -eq 3 -and @($ins.json.drives).Count -ge 1 -and $null -ne $ins.json.ram.goal) 'api: /api/insight có readiness (3 tác vụ), drives, ram.goal'
        $adv = Api 'GET' '/api/advice'
        Assert ($adv.code -eq 200 -and $adv.json.PSObject.Properties['generatedUtc'] -and $adv.json.PSObject.Properties['candidatesUtc'] -and $adv.json.PSObject.Properties['stale'] -and $adv.json.PSObject.Properties['goals'] -and $adv.json.PSObject.Properties['steps'] -and $adv.json.PSObject.Properties['review'] -and $adv.json.PSObject.Properties['afterPlan'] -and $adv.json.PSObject.Properties['beyond'] -and $adv.json.candidatesUtc) 'api: /api/advice đủ trường hợp đồng, dùng lượt quét ứng viên đã có'
        Assert (@($adv.json.steps | Where-Object { -not $_.id -or $null -eq $_.keys -or $null -eq $_.cumBytes -or -not $_.riskLevel -or -not $_.regen }).Count -eq 0) 'api: mọi bước advice có id/keys/cumBytes/riskLevel/regen'
        $ph = Api 'GET' '/api/process/history?name=ping&min=5'
        Assert ($ph.code -eq 200 -and $ph.json.name -eq 'ping' -and $null -ne $ph.json.totalRamMB) 'api: /api/process/history hợp lệ'
        Assert ((Api 'GET' '/api/process/history?name=a%3Bb').code -eq 400 -and (Api 'GET' '/api/process/history').code -eq 400) 'api: /api/process/history tên lạ / thiếu tên -> 400'
        Assert (@((Api 'GET' '/api/events?max=2').json).Count -le 2) 'api: /api/events?max=2 trả tối đa 2 sự kiện'
        $trNo = Api 'GET' '/api/disk/tree?drive=C'
        Assert ($trNo.code -eq 404 -and -not $trNo.json.ok -and $trNo.json.error) 'api: /api/disk/tree chưa có file cây -> 404 kèm lý do'
        Assert ((Api 'GET' '/api/disk/tree?drive=%3B').code -eq 400) 'api: /api/disk/tree tên ổ lạ -> 400'
        Copy-Item -LiteralPath (Join-Path $so 'scan-tree-C.json') -Destination (Join-Path $home_ 'state\scan-tree-C.json') -Force
        $trOk = Api 'GET' '/api/disk/tree?drive=C'
        Assert ($trOk.code -eq 200 -and $trOk.json.drive -eq 'C' -and $trOk.json.root.bytes -gt 0 -and $null -ne $trOk.json.root.children) 'api: /api/disk/tree trả { drive, root } từ file cây'
        Assert ((Api 'POST' '/api/disk/scan' @{ drive = 'C'; scope = 'bogus' }).code -eq 400) 'api: POST /api/disk/scan scope lạ -> 400'
        Assert ((Api 'POST' '/api/disk/scan' @{ drive = 'C'; scope = 'full' } $false).code -eq 403) 'api: POST /api/disk/scan thiếu X-RG-Client -> 403'
        $pv = Api 'POST' '/api/auto/preview' @{ policy = @{ mode = 'dry-run'; targetFreeGB = 25 } }
        Assert ($pv.code -eq 200 -and $pv.json.ok -and $null -ne $pv.json.now -and $null -ne $pv.json.forced -and $pv.json.needsPin -eq $false) 'api: POST /api/auto/preview -> now/forced/triggers14d/evidence/needsPin'
        Assert ((Get-RgPolicy).mode -eq 'off') 'api: preview không lưu bản nháp (chính sách vẫn Tắt)'
        Assert ((Api 'POST' '/api/auto/preview' @{ nothing = 1 }).code -eq 400) 'api: preview thiếu bản nháp -> 400'

        $pj = (Api 'GET' '/api/processes').json
        $row = @($pj.procs)[0]
        Assert ($null -ne $row -and $row.PSObject.Properties['start'] -and $row.PSObject.Properties['lowered'] -and $row.PSObject.Properties['canLower'] -and $row.PSObject.Properties['whyNot']) 'api: /api/processes có thêm start, lowered, canLower, whyNot'
        $srvRow = @($pj.procs | Where-Object { $_.pid -eq $srvProc.Id })[0]
        Assert ($srvRow -and -not $srvRow.canLower -and $srvRow.whyNot -match 'chính Resource Guard') 'api: tiến trình của chính server -> canLower = false, có whyNot'
        $apiPing = @($pj.procs | Where-Object { $_.pid -eq $prB.Id })[0]
        if ($apiPing) {
            Assert ($apiPing.canLower -eq $true -and $apiPing.start) 'api: tiến trình ping thử -> canLower = true'
            $bad = Api 'POST' '/api/process/priority' @{ pid = $prB.Id; start = '20200101T000000Z'; level = 'below' }
            Assert ($bad.code -eq 400 -and -not $bad.json.ok -and $bad.json.error -and (PClass $prB.Id) -eq 'Normal') 'api: POST /api/process/priority sai start -> 400 kèm lý do, không đổi gì'
            $okp = Api 'POST' '/api/process/priority' @{ pid = $prB.Id; start = $apiPing.start; level = 'below' }
            Assert ($okp.code -eq 200 -and $okp.json.to -eq 'BelowNormal' -and (PClass $prB.Id) -eq 'BelowNormal') 'api: POST /api/process/priority hạ ưu tiên thật qua HTTP'
            $pj2 = (Api 'GET' '/api/processes').json
            Assert (@($pj2.procs | Where-Object { $_.pid -eq $prB.Id })[0].lowered -eq $true) 'api: sau khi hạ, /api/processes báo lowered = true'
            $undo = Api 'POST' '/api/process/priority' @{ pid = $prB.Id; start = $apiPing.start; level = 'normal' }
            Assert ($undo.code -eq 200 -and (PClass $prB.Id) -eq 'Normal') 'api: hoàn tác qua HTTP trả về Normal'
        } else { Write-Host '  SKIP  api: chưa thấy ping thử trong bảng tiến trình của server' }
        Assert ((Api 'POST' '/api/process/priority' @{ pid = $srvProc.Id; start = $srvRow.start; level = 'below' }).code -eq 400) 'api: POST hạ ưu tiên chính server -> 400'
        Assert ((Api 'POST' '/api/process/priority' @{ pid = 'abc'; level = 'below' }).code -eq 400) 'api: PID không phải số -> 400'
    }
    finally {
        if ($srvProc -and -not $srvProc.HasExited) { Stop-Process -Id $srvProc.Id -Force -ErrorAction SilentlyContinue; [void]$srvProc.WaitForExit(8000) }
    }
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $j = Join-Path $ws 'proj\obj'
    if (Test-Path $j) { (Get-Item $j -Force).Delete() }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_RESOURCE_HOME -ErrorAction SilentlyContinue
}
# Bộ test của plan-automation chạy ở process riêng (sandbox riêng); cộng kết quả vào tổng.
$autoTest = Join-Path $PSScriptRoot 'Acceptance-Auto.ps1'
if (Test-Path -LiteralPath $autoTest) {
    Write-Host "`n[Acceptance-Auto] plan-automation"
    $autoOut = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $autoTest 2>&1 | Out-String
    $autoOut.TrimEnd() -split "`r?`n" | ForEach-Object { if ($_ -match '^\s+(PASS|FAIL)|^\[|^$') { Write-Host $_ } }
    if ($autoOut -match 'AUTO-RESULT pass=(\d+) fail=(\d+)') { $script:pass += [int]$Matches[1]; $script:fail += [int]$Matches[2] }
    else { $script:fail++; Write-Host '  FAIL  Acceptance-Auto.ps1 không trả kết quả' -ForegroundColor Red }
}
Write-Host ("`nKết quả: {0} pass, {1} fail" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
