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
    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object { $_.LastWriteTime = $t; $_.LastAccessTime = $t }
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

    Write-Host "`n[policy] chính sách, vùng bảo vệ, PIN, engine tự dọn"
    . (Join-Path $root 'scripts\rg-policy.ps1')
    $hostExe = (Get-Process -Id $PID).Path
    NewFile (Join-Path $home_ 'state\rwtest.json') 5
    Assert ((Read-RgFileShared (Join-Path $home_ 'state\rwtest.json')).Length -eq 5) 'Read-RgFileShared đọc được file (đối số -bor trong ngoặc)'
    $p0 = Get-RgPolicy
    Assert ($p0.mode -eq 'off' -and $p0.categories['cache-aged'] -eq 'ask' -and $p0.categories['temp-entry'] -eq 'auto') 'policy: mặc định mode off, nhóm rủi ro cao không auto'
    $bad = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'nuke'; maxGBPerRun = 99999; categories = [pscustomobject]@{ 'cache-aged' = 'bogus'; 'evil' = 'auto' }; protectPaths = @('relative\x', 'C:\ok\path'); protectProcesses = @('SqlServr', "bad`nname") })
    Assert ($bad.mode -eq 'off' -and $bad.maxGBPerRun -eq 500) 'policy: mode lạ -> off, số vượt kẹp về giới hạn'
    Assert ($bad.categories['cache-aged'] -eq 'ask' -and -not $bad.categories.Contains('evil')) 'policy: giá trị nhóm lạ bị bỏ, nhóm lạ bị loại'
    Assert (@($bad.protectPaths).Count -eq 1 -and $bad.protectPaths[0] -eq 'C:\ok\path' -and @($bad.protectProcesses).Count -eq 1 -and $bad.protectProcesses[0] -eq 'sqlservr') 'policy: chỉ nhận đường dẫn tuyệt đối, tên tiến trình chữ thường, bỏ ký tự điều khiển'
    $keepDir = Join-Path $ws 'keepme'
    $pp = ConvertTo-RgPolicy ([pscustomobject]@{ protectPaths = @($keepDir); protectProcesses = @('node*', 'devenv') })
    Assert ((Test-RgPathProtected "$keepDir\obj" $pp) -and (Test-RgPathProtected $keepDir $pp)) 'protect: mục nằm trong/bằng thư mục bảo vệ'
    Assert ((Test-RgPathProtected $ws $pp) -and -not (Test-RgPathProtected "${keepDir}x" $pp) -and -not (Test-RgPathProtected (Join-Path $ws 'other') $pp)) 'protect: cha của vùng bảo vệ bị chặn, thư mục anh em tên gần giống thì không'
    Assert ((Test-RgProcessProtected 'nodemon' $pp) -and (Test-RgProcessProtected 'DevEnv' $pp) -and -not (Test-RgProcessProtected 'devenv2' $pp)) 'protect: tiến trình khớp wildcard, không phân biệt hoa thường'
    $off = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'off' }); $on = ConvertTo-RgPolicy ([pscustomobject]@{ mode = 'on'; protectProcesses = @('a') })
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
    Assert ($null -eq (Get-RgJobState 'nope.json')) 'job: file không tồn tại -> null'
    Write-RgJobState 'zombie.progress.json' ([ordered]@{ pid = 999999; status = 'running'; message = '' })
    Assert ((Get-RgJobState 'zombie.progress.json').status -eq 'error') 'job: tiến trình đã chết mà vẫn "running" -> báo error'

    # rg-cleanup.ps1 (đường UI): chỉ nhận key, từ chối mục được bảo vệ / key lạ
    $cl1 = Join-Path $tmp 'ui-old'; NewFile (Join-Path $cl1 'f.bin') 1024; Age $cl1 30
    $keepProj2 = Join-Path $ws 'keepme\sub'; NewFile (Join-Path $keepProj2 's.csproj') 10; NewFile (Join-Path $keepProj2 'obj\o.dll') 100; Age (Join-Path $keepProj2 'obj') 30
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\rg-scan.ps1') -Mode candidates | Out-Null
    $cd = Get-Content (Join-Path $home_ 'state\scan-candidates.json') -Raw | ConvertFrom-Json
    $kTmp = @($cd.items | Where-Object { $_.path -eq $cl1 })[0].key
    $kProt = @($cd.items | Where-Object { $_.path -eq (Join-Path $keepProj2 'obj') })[0].key
    Assert ($kTmp -match '^[0-9a-f]{12}$' -and $kProt) 'scan candidates: có key ổn định cho từng mục'
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
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $j = Join-Path $ws 'proj\obj'
    if (Test-Path $j) { (Get-Item $j -Force).Delete() }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_RESOURCE_HOME -ErrorAction SilentlyContinue
}
Write-Host ("`nKết quả: {0} pass, {1} fail" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
