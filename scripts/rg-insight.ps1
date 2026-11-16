# rg-insight.ps1 - số liệu "hiểu được" dựng từ dữ liệu có sẵn, KHÔNG lấy mẫu máy, KHÔNG quét ổ:
#   Get-RgForecast   : hồi quy tuyến tính dung lượng trống -> còn bao nhiêu ngày tới Cần chú ý / Nguy cấp / đầy
#   Get-RgReadiness  : máy có đủ chỗ cho build / test / subagent không (Get-RgBudget trên snapshot + bảng tiến trình đã có)
#   Get-RgInsight    : gộp hai thứ trên + "cần thêm bao nhiêu để về mức Ổn" cho từng ổ và RAM (GET /api/insight)
# Dot-source sau rg-common.ps1 (rg-server.ps1 nạp file này). Chỉ ĐỌC.

# Đọc dòng ĐẦU TIÊN của mỗi giờ trong một file metrics (ts >= cutoff) bằng C# để 14 ngày metrics không phải duyệt từng dòng bằng PowerShell.
# Mở với FileShare.ReadWrite vì watcher đang ghi file cùng lúc. C# 5 để chạy được trên Windows PowerShell 5.1.
if (-not ('RgMetricsReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class RgMetricsReader
{
    public static string[] FirstPerHour(string path, string cutoff)
    {
        List<string> res = new List<string>();
        string lastHour = null;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
        {
            string line;
            while ((line = sr.ReadLine()) != null)
            {
                int i = line.IndexOf("\"ts\":\"", StringComparison.Ordinal);
                if (i < 0 || line.Length < i + 6 + 19) continue;
                string ts = line.Substring(i + 6, 19);
                if (string.CompareOrdinal(ts, cutoff) < 0) continue;
                string hour = ts.Substring(0, 13);
                if (hour == lastHour) continue;
                lastHour = hour;
                res.Add(line);
            }
        }
        return res.ToArray();
    }

    // Mọi dòng của file chứa chuỗi $needle (so khớp thô, không phân biệt vị trí). Dùng để lọc log JSONL lớn trước khi parse.
    public static string[] Grep(string path, string needle)
    {
        List<string> res = new List<string>();
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
        {
            string line;
            while ((line = sr.ReadLine()) != null)
            {
                if (line.IndexOf(needle, StringComparison.Ordinal) >= 0) res.Add(line);
            }
        }
        return res.ToArray();
    }
}
'@
}

# Mẫu dung lượng trống của từng ổ, mỗi giờ một điểm, từ tối đa $Days file metrics gần nhất.
# Trả về hashtable: 'C' -> @([pscustomobject]@{ t = [datetime]; freeGB = 8.6 }, ...) theo thứ tự thời gian.
function Read-RgDriveSamples([int]$Days = 14, $Now = $null) {
    if ($null -eq $Now) { $Now = Get-Date }
    $Now = [datetime]$Now
    $dir = Join-Path (Initialize-RgHome) 'state'
    $cutoff = $Now.AddDays(-$Days).ToString('yyyy-MM-dd HH:mm:ss')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $out = @{}
    for ($d = $Now.AddDays(-$Days).Date; $d -le $Now.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ('metrics-{0}.jsonl' -f $d.ToString('yyyyMMdd'))
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = $null
        try { $lines = [RgMetricsReader]::FirstPerHour($f, $cutoff) } catch { continue }
        foreach ($l in $lines) {
            try {
                $r = ConvertFrom-Json $l
                $t = [datetime]::ParseExact([string]$r.ts, 'yyyy-MM-dd HH:mm:ss', $inv)
                $ds = @($r.drives)
                if ($ds.Count -eq 0 -or $null -eq $ds[0]) { $ds = @([pscustomobject]@{ drive = [string]$r.diskDrive; freeGB = $r.diskFreeGB }) }
                foreach ($x in $ds) {
                    if (-not $x.drive -or $null -eq $x.freeGB) { continue }
                    $k = ([string]$x.drive).ToUpperInvariant()
                    if (-not $out.ContainsKey($k)) { $out[$k] = New-Object System.Collections.ArrayList }
                    [void]$out[$k].Add([pscustomobject]@{ t = $t; freeGB = [double]$x.freeGB })
                }
            } catch { }
        }
    }
    return $out
}

# Dự báo cho MỘT ổ. $Samples = @({ t; freeGB }) (đã lấy thưa); $FreeGB = dung lượng trống hiện tại; $Thr = Get-RgDiskThresholds.
#   Trạng thái Cần chú ý khi free <= normalAboveGB; Nguy cấp khi free < cautionFromGB.
#   confidence: 'low' nếu < 3 ngày dữ liệu hoặc dốc >= 0 (khi đó mọi daysTo* = $null); 'medium' 3-7 ngày; 'high' > 7 ngày.
#   Số ngày làm tròn xuống; ổ đã ở/qua ngưỡng thì 0.
function Get-RgForecast($Samples, [double]$FreeGB, $Thr) {
    $s = @($Samples | Where-Object { $_ } | Sort-Object { $_.t })
    $res = [ordered]@{ slopeGBPerDay = 0.0; daysToCaution = $null; daysToCritical = $null; daysToFull = $null; confidence = 'low'; sampleDays = 0 }
    if ($s.Count -lt 2) { return $res }
    $t0 = $s[0].t
    $xs = @($s | ForEach-Object { ($_.t - $t0).TotalDays })
    $ys = @($s | ForEach-Object { [double]$_.freeGB })
    $span = $xs[$xs.Count - 1]
    $res.sampleDays = [int][math]::Round($span)
    $n = $xs.Count; $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
    $sxy = 0.0; $sxx = 0.0
    for ($i = 0; $i -lt $n; $i++) { $sxy += ($xs[$i] - $mx) * ($ys[$i] - $my); $sxx += ($xs[$i] - $mx) * ($xs[$i] - $mx) }
    if ($sxx -le 0) { return $res }
    $slope = $sxy / $sxx
    $res.slopeGBPerDay = [math]::Round($slope, 2)
    if ($span -lt 3 -or $slope -ge 0) { return $res }   # confidence 'low', daysTo* = $null
    $res.confidence = if ($span -gt 7) { 'high' } else { 'medium' }
    $down = -$slope
    $res.daysToCaution = [int][math]::Max(0, [math]::Floor(($FreeGB - [double]$Thr.normalAboveGB) / $down))
    $res.daysToCritical = [int][math]::Max(0, [math]::Floor(($FreeGB - [double]$Thr.cautionFromGB) / $down))
    $res.daysToFull = [int][math]::Max(0, [math]::Floor($FreeGB / $down))
    return $res
}

# Lý do chặn: concurrency | ram | disk | commit | state. '' nếu được phép.
function Get-RgReadiness($Snapshot, $Table, $Cfg = $null) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    $out = @()
    foreach ($task in 'build', 'test', 'subagent') {
        $b = Get-RgBudget -Task $task -Snapshot $Snapshot -Table $Table
        $ok = ($b.decision -ne 'deny')
        $blocker = ''
        if (-not $ok) {
            $projState = Get-RgRamState ([double]$Snapshot.availRamGB - [double]$b.estimateGB) $Cfg
            if (@($b.reasons | Where-Object { $_ -like 'concurrency budget reached*' }).Count -gt 0) { $blocker = 'concurrency' }
            elseif ($b.ramState -ne 'Normal' -or $projState -ne 'Normal') { $blocker = 'ram' }
            elseif ($b.diskState -ne 'Normal') { $blocker = 'disk' }
            elseif ($b.commitState -ne 'Normal') { $blocker = 'commit' }
            else { $blocker = 'state' }
        }
        $out += [ordered]@{ task = $task; ok = $ok; needGB = [double]$b.estimateGB; haveGB = [double]$Snapshot.availRamGB; blocker = $blocker }
    }
    return $out
}

# Cache 10 phút cho phần đọc metrics (tốn nhất) để route /api/insight trả nhanh.
$script:RgSamplesCache = $null; $script:RgSamplesCacheAt = [datetime]::MinValue
function Get-RgDriveSamplesCached([int]$Days = 14) {
    if ($null -eq $script:RgSamplesCache -or ((Get-Date) - $script:RgSamplesCacheAt).TotalMinutes -ge 10) {
        $script:RgSamplesCache = Read-RgDriveSamples $Days
        $script:RgSamplesCacheAt = Get-Date
    }
    return $script:RgSamplesCache
}

# Sự kiện ghi trong logs\rg-*.jsonl từ $Since (UTC) trở đi, chỉ các loại $Names. Đọc từng dòng và lọc bằng chuỗi trước khi parse JSON.
function Read-RgEventsSince($Since, [string[]]$Names) {
    $dir = Join-Path (Initialize-RgHome) 'logs'
    $pat = '"event":"(' + ($Names -join '|') + ')"'
    $out = New-Object System.Collections.ArrayList
    $cut = ([datetime]$Since).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'rg-*.jsonl' -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt ([datetime]$Since).ToLocalTime().AddDays(-1)) { continue }
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 | Where-Object { $_ -match $pat })) {
            try { $e = ConvertFrom-Json $l; if ([string]$e.ts -ge $cut) { [void]$out.Add($e) } } catch { }
        }
    }
    return @($out)
}

# 7 ngày qua Resource Guard đã làm gì: số lượt tự dọn thật/chạy thử + dung lượng, dọn tay, và số lần trạng thái xấu đi (alerts).
function Get-RgWeekSummary($Events = $null, $Now = $null) {
    if ($null -eq $Now) { $Now = Get-Date }
    if ($null -eq $Events) { $Events = Read-RgEventsSince (([datetime]$Now).AddDays(-7).ToUniversalTime()) @('auto-run', 'manual-cleanup', 'state-change') }
    $cut = ([datetime]$Now).AddDays(-7).ToString('yyyy-MM-dd HH:mm:ss')
    $rank = @{ Normal = 0; Caution = 1; Restricted = 2; Critical = 3 }
    $w = [ordered]@{ autoRuns = 0; autoBytes = 0L; dryRuns = 0; dryBytes = 0L; alerts = 0; manualRuns = 0; manualBytes = 0L }
    foreach ($e in @($Events)) {
        if (-not $e -or [string]$e.ts -lt $cut) { continue }
        $d = $e.data
        switch ([string]$e.event) {
            'auto-run' {
                if ([string]$d.mode -eq 'dry-run') {
                    $w.dryRuns++
                    if ($d.byKind) { foreach ($p in $d.byKind.PSObject.Properties) { $w.dryBytes += [long]$p.Value.bytes } }
                } else { $w.autoRuns++; $w.autoBytes += [long]$d.freedBytes }
            }
            'manual-cleanup' { $w.manualRuns++; $w.manualBytes += [long]$d.freedBytes }
            'state-change' { if ($rank.ContainsKey([string]$d.to) -and $rank.ContainsKey([string]$d.from) -and $rank[[string]$d.to] -gt $rank[[string]$d.from]) { $w.alerts++ } }
        }
    }
    return $w
}

# $Snapshot: availRamGB, commitPct, diskDrive, diskFreeGB, drives[{drive,freeGB,...}] (live của server dùng được ngay).
# $Samples: hashtable drive -> mẫu (mặc định đọc metrics qua cache). $Table: bảng tiến trình server đang giữ.
function Get-RgInsight($Snapshot, $Table, $Samples = $null, $Cfg = $null, $Events = $null) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Samples) { $Samples = Get-RgDriveSamplesCached 14 }
    $ds = @($Snapshot.drives | Where-Object { $_ })
    if ($ds.Count -eq 0 -and $Snapshot.diskDrive) { $ds = @([pscustomobject]@{ drive = [string]$Snapshot.diskDrive; freeGB = $Snapshot.diskFreeGB }) }
    $drives = @()
    foreach ($d in $ds) {
        $letter = ([string]$d.drive).ToUpperInvariant()
        $free = [double]$d.freeGB
        $thr = Get-RgDiskThresholds $Cfg $letter
        $state = Get-RgDiskState $free $Cfg $letter
        $fc = Get-RgForecast @($Samples[$letter]) $free $thr
        $need = $null
        if ($free -le [double]$thr.normalAboveGB) { $need = [math]::Round([double]$thr.normalAboveGB - $free, 1) }
        $drives += [ordered]@{
            drive = $letter; freeGB = $free; state = $state
            slopeGBPerDay = $fc.slopeGBPerDay; daysToCaution = $fc.daysToCaution; daysToCritical = $fc.daysToCritical; daysToFull = $fc.daysToFull
            confidence = $fc.confidence; sampleDays = $fc.sampleDays
            goal = [ordered]@{ toState = 'Normal'; needGB = $need }
        }
    }
    $avail = [double]$Snapshot.availRamGB
    $ramNeed = $null
    if ($avail -le [double]$Cfg.ram.normalAboveGB) { $ramNeed = [math]::Round([double]$Cfg.ram.normalAboveGB - $avail, 1) }
    return [ordered]@{
        readiness = @(Get-RgReadiness $Snapshot $Table $Cfg)
        drives    = $drives
        ram       = [ordered]@{ availGB = $avail; state = (Get-RgRamState $avail $Cfg); goal = [ordered]@{ toState = 'Normal'; needGB = $ramNeed } }
        week      = (Get-RgWeekSummary $Events)
    }
}

# ---------- Advice: kế hoạch đề xuất TẤT ĐỊNH (không cần LLM) ----------

$script:RgRegenCoef = @{ 'auto' = 1.0; 'rebuild' = 0.9; 'redownload' = 0.7; 'restore-zip' = 0.4; 'none' = 0.3 }
$script:RgRiskCoef = @{ 'low' = 1.0; 'medium' = 0.6; 'high' = 0.3 }
$script:RgRiskRank = @{ 'low' = 0; 'medium' = 1; 'high' = 2 }
$script:RgStepTitles = @{
    'temp-entry' = 'File tạm cũ'; 'dotnet-artifact' = 'bin/obj cũ'; 'node_modules' = 'node_modules không dùng'
    'cache-aged' = 'Bộ nhớ đệm gói không dùng'; 'stale-repo' = 'Repo lâu không đụng tới'; 'large-item' = 'Mục lớn lâu không dùng'
}
# Nhóm của lượt quét ổ mà Resource Guard dọn được (đã nằm trong các bước) -> không đưa vào 'beyond'.
$script:RgCleanableCats = @('temp', 'dev-cache', 'node-modules', 'build-output')
$script:RgBeyondHints = @{
    'programs' = 'Gỡ ứng dụng ít dùng ở Cài đặt > Ứng dụng'
    'system-windows' = 'Phần hệ thống Windows; dùng Dọn dẹp ổ đĩa (cleanmgr) hoặc Storage Sense'
    'program-data' = 'Dữ liệu dùng chung của chương trình; xem chương trình nào chiếm nhiều ở ProgramData'
    'recycle-bin' = 'Làm trống Thùng rác'
    'user-other' = 'Hồ sơ người dùng khác trên máy; kiểm tra xem còn dùng không'
    'documents' = 'Tài liệu, ảnh, video của bạn; chuyển sang ổ khác hoặc lưu lên đám mây'
    'downloads' = 'Xoá hoặc chuyển bớt file trong thư mục Tải xuống'
    'app-data' = 'Dữ liệu ứng dụng (AppData); dọn ngay trong ứng dụng đang chiếm nhiều'
    'repos' = 'Mã nguồn dự án; kho lâu không dùng có thể nén hoặc xoá thủ công'
    'git-data' = 'Dữ liệu .git; chạy git gc hoặc xoá bản clone không dùng'
    'vm-disks' = 'Ổ ảo (WSL/Docker/VM); thu gọn thủ công (docker builder prune, wsl --manage <distro> --set-sparse true)'
    'system-files' = 'pagefile/hiberfil do Windows quản lý; tắt ngủ đông (powercfg /h off) nếu không cần'
    'other' = 'File khác ở gốc ổ; mở trang Ổ đĩa để xem chi tiết'
}

function Read-RgStateJson([string]$Name) {
    $p = Join-Path (Initialize-RgHome) ('state\' + $Name)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json (Read-RgFileShared $p)) } catch { return $null }
}

function Get-RgItemScore($It) {
    $rc = 0.3; $rk = 0.3
    if ($script:RgRegenCoef.ContainsKey([string]$It.regen)) { $rc = $script:RgRegenCoef[[string]$It.regen] }
    if ($script:RgRiskCoef.ContainsKey([string]$It.riskLevel)) { $rk = $script:RgRiskCoef[[string]$It.riskLevel] }
    return ([double]$It.sizeBytes * $rc * $rk)
}

# Dựng một bước từ danh sách mục (đã cùng ổ). $Kind = kind thật; bước < 50 MB giữ nguyên kind và riskLevel, chỉ đánh dấu minor.
function New-RgAdviceStep([string]$Drive, [string]$Kind, $Items, $Policy, $Cfg) {
    $its = @($Items)
    $bytes = 0L; $score = 0.0; $risk = 'low'; $regen = 'auto'
    foreach ($i in $its) {
        $bytes += [long]$i.sizeBytes; $score += (Get-RgItemScore $i)
        if ($script:RgRiskRank[[string]$i.riskLevel] -gt $script:RgRiskRank[$risk]) { $risk = [string]$i.riskLevel }
        $rc = 0.3; if ($script:RgRegenCoef.ContainsKey([string]$i.regen)) { $rc = $script:RgRegenCoef[[string]$i.regen] }
        if ($rc -lt $script:RgRegenCoef[$regen]) { $regen = [string]$i.regen }   # lấy cách lấy lại KHÓ nhất
    }
    $first = $its | Sort-Object { [long]$_.sizeBytes } -Descending | Select-Object -First 1
    $auto = 'ask'
    $title = if ($script:RgStepTitles.ContainsKey($Kind)) { $script:RgStepTitles[$Kind] } else { $Kind }
    if ($Kind -eq 'cache-aged') { try { $title = "Gói trong bộ nhớ đệm không dùng $([int]$Cfg.cleanup.cacheMinInactiveDays) ngày" } catch { } }
    if ($Policy.categories.Contains($Kind)) { $auto = [string]$Policy.categories[$Kind] }
    $sz = Format-RgSizeVi $bytes
    $why = if ($its.Count -eq 1) { [string]$first.why } else { "$($its.Count) mục cùng loại ($sz). Mục lớn nhất: $([string]$first.why)" }
    return [ordered]@{
        id = "${Drive}:$Kind"; drive = $Drive; kind = $Kind; title = $title
        resource = 'disk'; actionType = 'delete'; manual = $false; minor = ($bytes -lt 50MB)
        keys = @($its | ForEach-Object { [string]$_.key }); count = $its.Count; bytes = $bytes
        riskLevel = $risk; regen = $regen; regenHint = [string]$first.regenHint; why = $why; impact = [string]$first.impact
        auto = $auto; cumBytes = 0L; reachesGoal = $false; agent = $null; _score = $score; _items = $its
    }
}

<#
Get-RgAdvice - kế hoạch dọn 1-5 bước mỗi ổ, tất định, chỉ ĐỌC (không quét). Trả về object của GET /api/advice.
Quy tắc (test từng điều):
 1. Loại khỏi bước: action=report, mục trong vùng bảo vệ (người dùng đặt), mục agent-keep, mục không thuộc ổ nào (tiến trình).
    Mục `young` và mục `needsAdmin` KHÔNG vào bước mà vào `review` (người/agent phải cân nhắc). Mục nằm TRONG một mục dọn khác
    (đường dẫn con) bị bỏ khỏi bước để không đếm dung lượng hai lần.
 2. Gộp theo (drive, kind) thành bước. Điểm bước = Σ bytes × hệ số regen (auto 1.0, rebuild 0.9, redownload 0.7, restore-zip 0.4, none 0.3)
    × hệ số rủi ro (low 1.0, medium 0.6, high 0.3). `auto` của bước = chế độ nhóm trong chính sách (nhóm ngoài chính sách = 'ask').
 3. Sắp theo điểm giảm dần trong từng ổ; bước < 50 MB giữ kind và riskLevel thật, đánh dấu minor=true và đứng cuối (UI gộp hiển thị).
    Không còn kind 'small'. Tài nguyên có trạng thái xấu nhất đứng trước (ổ có mục tiêu trước ổ không có; ổ/RAM cùng mức: ổ trước).
 3b. RAM (khi có $Ram và trạng thái không phải Ổn): goal { resource='ram', needBytes, state } và tối đa 3 bước kind='close-app' (manual=true) lấy từ
    $Workloads theo RAM giảm dần, bỏ agent/system/security/infra/unknown/được bảo vệ, dừng khi đủ đưa RAM về Ổn.
 4. cumBytes cộng dồn trong từng ổ; reachesGoal = true ở bước đầu tiên làm tổng >= needBytes (mục tiêu = đưa ổ lên mức Ổn).
 5. afterPlan = trạng thái ổ nếu làm hết các bước; shortBytes > 0 nghĩa là dọn hết vẫn chưa đủ -> `beyond` = 3 nhóm lớn nhất của lượt
    quét ổ (scan-breakdown-<X>.json) không thuộc loại dọn được, kèm gợi ý việc tự làm.
 6. Nếu agent-last.json (ok) mới hơn lượt quét ứng viên: gắn agent {verdict, reason, confidence} theo key; key bị agent 'keep' rời khỏi
    bước (sau khi đã sắp thứ tự: không đổi thứ tự bước).
 7. stale = true khi lượt quét ứng viên cũ hơn 6 giờ (hoặc chưa có).
Tham số cho phép test truyền dữ liệu giả; bỏ trống thì đọc từ state/ và Get-RgDrives.
#>
function Get-RgAdvice($Candidates = $null, $Breakdowns = $null, $Agent = $null, $Policy = $null, $Drives = $null, $Cfg = $null, $Now = $null, $Ram = $null, $Workloads = $null) {
    if ($null -eq $Cfg) { $Cfg = Get-RgConfig }
    if ($null -eq $Policy) { $Policy = Get-RgPolicy }
    if ($null -eq $Now) { $Now = (Get-Date).ToUniversalTime() }
    $Now = ([datetime]$Now).ToUniversalTime()
    if ($null -eq $Candidates) { $Candidates = Read-RgStateJson 'scan-candidates.json' }
    if ($null -eq $Agent) { $Agent = Read-RgStateJson 'agent-last.json' }
    if ($null -eq $Drives) { $Drives = @(Get-RgDrives) }
    if ($null -eq $Breakdowns) {
        $Breakdowns = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path (Initialize-RgHome) 'state') -Filter 'scan-breakdown-?.json' -ErrorAction SilentlyContinue)) {
            $o = Read-RgStateJson $f.Name; if ($o -and $o.drive) { $Breakdowns[[string]$o.drive] = $o }
        }
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $parseUtc = { param($s) try { return [datetime]::Parse([string]$s, $inv, 'RoundtripKind').ToUniversalTime() } catch { return $null } }
    $candUtc = $null; if ($Candidates) { $candUtc = & $parseUtc $Candidates.finishedUtc }
    $stale = ($null -eq $candUtc) -or (($Now - $candUtc).TotalHours -gt 6)

    # Mục tiêu theo ổ
    $goals = @(); $goalByDrive = @{}
    foreach ($d in @($Drives)) {
        $L = ([string]$d.drive).ToUpperInvariant(); $free = [double]$d.freeGB
        $thr = Get-RgDiskThresholds $Cfg $L
        if ($free -le [double]$thr.normalAboveGB) {
            $need = [long][math]::Ceiling(([double]$thr.normalAboveGB - $free) * 1GB)
            $g = [ordered]@{ resource = 'disk'; drive = $L; freeGB = $free; needBytes = $need; toState = 'Normal'; state = (Get-RgDiskState $free $Cfg $L) }
            $goals += $g; $goalByDrive[$L] = $g
        }
    }

    # Agent: chỉ dùng khi MỚI HƠN lượt quét ứng viên
    $agentByKey = @{}
    if ($Agent -and $Agent.ok -and $Agent.result) {
        $aUtc = & $parseUtc $Agent.finishedUtc
        if ($aUtc -and $candUtc -and $aUtc -gt $candUtc) {
            foreach ($r in @($Agent.result.recommendations)) { if ($r.key) { $agentByKey[[string]$r.key] = $r } }
        }
    }

    # Phân loại mục
    $elig = @(); $reviewItems = @()
    foreach ($it0 in @($Candidates.items)) {
        $it = $it0
        if (-not $it.riskLevel) {   # lượt quét cũ chưa có biên lai
            $rc = Get-RgItemReceipt $it $Cfg
            $it = [pscustomobject]@{ key = $it0.key; kind = $it0.kind; action = $it0.action; path = $it0.path; drive = $it0.drive; sizeBytes = $it0.sizeBytes; young = $it0.young; needsAdmin = $it0.needsAdmin
                why = $rc.why; impact = $rc.impact; regen = $rc.regen; regenHint = $rc.regenHint; riskLevel = $rc.riskLevel }
        }
        $drv = [string]$it.drive; if (-not $drv) { $drv = [string](Get-RgPathDrive ([string]$it.path)) }
        if (-not $drv -or [string]$it.kind -eq 'process') { continue }
        $path = [string]$it.path
        if (Test-RgPathUserProtected $path $Policy) { continue }
        if (Get-RgAgentKeepMatch $path) { continue }
        if ([bool]$it.needsAdmin -or ([bool]$it.young -and [string]$it.action -eq 'delete')) { $reviewItems += $it; continue }
        if ([string]$it.action -ne 'delete') { continue }
        $elig += [pscustomobject]@{ item = $it; drive = $drv.ToUpperInvariant() }
    }
    # Bỏ mục nằm trong mục dọn khác (không đếm hai lần)
    $paths = @($elig | ForEach-Object { ([string]$_.item.path).TrimEnd('\') })
    $elig = @($elig | Where-Object {
            $p = ([string]$_.item.path).TrimEnd('\'); $nested = $false
            foreach ($q in $paths) { if ($q -ne $p -and $p.StartsWith($q + '\', [StringComparison]::OrdinalIgnoreCase)) { $nested = $true; break } }
            -not $nested })

    # Các bước theo ổ
    $steps = @(); $afterPlan = @(); $beyond = @(); $groups = @(); $gIdx = 0
    $stateRank = @{ Normal = 0; Caution = 1; Restricted = 2; Critical = 3 }
    $driveOrder = @(@($elig | ForEach-Object { $_.drive }) + @($goals | ForEach-Object { $_.drive }) | Select-Object -Unique)
    $driveOrder = @($driveOrder | Sort-Object @{ Expression = { if ($goalByDrive.ContainsKey($_)) { 0 } else { 1 } } }, @{ Expression = { $_ } })
    foreach ($L in $driveOrder) {
        $mine = @($elig | Where-Object { $_.drive -eq $L } | ForEach-Object { $_.item })
        $big = @(); $small = @()
        foreach ($grp in @($mine | Group-Object kind)) {
            $st = New-RgAdviceStep $L ([string]$grp.Name) @($grp.Group) $Policy $Cfg
            if ($st.minor) { $small += $st } else { $big += $st }
        }
        $big = @($big | Sort-Object @{ Expression = { $_._score }; Descending = $true })
        $small = @($small | Sort-Object @{ Expression = { $_._score }; Descending = $true })
        $ordered = @($big) + @($small)

        # Agent: gắn nhãn, bỏ key 'keep' (SAU khi đã sắp thứ tự)
        $kept = @()
        foreach ($st in $ordered) {
            if ($agentByKey.Count -gt 0) {
                $byKey = [ordered]@{}; $remain = @()
                foreach ($i in $st._items) {
                    $r = $agentByKey[[string]$i.key]
                    if ($r) { $byKey[[string]$i.key] = [ordered]@{ verdict = [string]$r.verdict; reason = [string]$r.reason; confidence = [string]$r.confidence } }
                    if (-not ($r -and [string]$r.verdict -eq 'keep')) { $remain += $i }
                }
                if ($remain.Count -eq 0) { continue }
                if ($remain.Count -ne $st._items.Count) { $o = $st; $st = New-RgAdviceStep $L $o.kind $remain $Policy $Cfg; $st.title = $o.title }
                if ($byKey.Count -gt 0) {
                    $pick = $null
                    foreach ($i in $st._items) { $v = $byKey[[string]$i.key]; if ($v -and (-not $pick -or ($v.verdict -eq 'clean' -and $pick.verdict -ne 'clean'))) { $pick = $v } }
                    $st.agent = $pick; $st['agentByKey'] = $byKey
                }
            }
            $kept += $st
        }
        $cum = 0L; $hit = $false; $need = 0L
        if ($goalByDrive.ContainsKey($L)) { $need = [long]$goalByDrive[$L].needBytes }
        foreach ($st in $kept) {
            $cum += [long]$st.bytes; $st.cumBytes = $cum
            if ($need -gt 0 -and -not $hit -and $cum -ge $need) { $st.reachesGoal = $true; $hit = $true }
        }
        foreach ($st in $kept) { [void]$st.Remove('_score'); [void]$st.Remove('_items') }
        $dRank = 0; if ($goalByDrive.ContainsKey($L)) { $dRank = [int]$stateRank[[string]$goalByDrive[$L].state] }
        $groups += [pscustomobject]@{ rank = $dRank; idx = $gIdx; steps = @($kept) }; $gIdx++

        $dr = @($Drives | Where-Object { ([string]$_.drive).ToUpperInvariant() -eq $L }) | Select-Object -First 1
        if ($dr) {
            $afterFree = [double]$dr.freeGB + $cum / 1GB
            $short = [long][math]::Max(0L, [long]($need - $cum))
            $afterPlan += [ordered]@{ resource = 'disk'; drive = $L; freeGB = [math]::Round($afterFree, 1); state = (Get-RgDiskState $afterFree $Cfg $L); shortBytes = $short }
            if ($short -gt 0) {
                $bd = $null
                if ($Breakdowns -is [System.Collections.IDictionary]) { if ($Breakdowns.Contains($L)) { $bd = $Breakdowns[$L] } }
                else { $bd = @($Breakdowns | Where-Object { [string]$_.drive -eq $L }) | Select-Object -First 1 }
                if ($bd) {
                    foreach ($c in @($bd.categories | Where-Object { $script:RgCleanableCats -notcontains [string]$_.cat } | Sort-Object { [long]$_.bytes } -Descending | Select-Object -First 3)) {
                        $h = if ($script:RgBeyondHints.ContainsKey([string]$c.cat)) { $script:RgBeyondHints[[string]$c.cat] } else { 'Mở trang Ổ đĩa để xem chi tiết' }
                        $beyond += [ordered]@{ drive = $L; cat = [string]$c.cat; bytes = [long]$c.bytes; hint = $h }
                    }
                }
            }
        }
    }
    # RAM: bước đóng ứng dụng (luôn thủ công); chỉ đề xuất, không tự đóng gì
    if ($null -ne $Ram) {
        $avail = [double]$Ram.availGB
        $rState = Get-RgRamState $avail $Cfg
        if ($rState -ne 'Normal') {
            $need = [long][math]::Ceiling(([double]$Cfg.ram.normalAboveGB - $avail) * 1GB)
            $goals += [ordered]@{ resource = 'ram'; drive = 'RAM'; freeGB = $avail; needBytes = $need; toState = 'Normal'; state = $rState }
            $skipRoles = @('agent', 'system', 'security', 'infra', 'unknown')
            $cands = @(@($Workloads) | Where-Object { $_ -and $skipRoles -notcontains [string]$_.role -and -not $_.protected -and [double]$_.ramMB -ge 100 } | Sort-Object { [double]$_.ramMB } -Descending)
            $rsteps = @(); $cum = 0L; $hitR = $false
            foreach ($w in $cands) {
                if ($rsteps.Count -ge 3 -or $cum -ge $need) { break }
                $b = [long]([double]$w.ramMB * 1MB); $cum += $b
                $nm = [string]$w.title; if ($w.project) { $nm += ' — ' + [string]$w.project }
                $what = $(if ($w.PSObject.Properties['what'] -and $w.what) { [string]$w.what } else { [string]$w.title })
                $reach = ((-not $hitR) -and $cum -ge $need); if ($reach) { $hitR = $true }
                $rsteps += [ordered]@{
                    id = 'RAM:close-app:' + [string]$w.key; drive = 'RAM'; kind = 'close-app'; title = ('Đóng ' + $nm)
                    resource = 'ram'; actionType = 'close-app'; workload = [string]$w.key; manual = $true; minor = $false
                    keys = @(); count = [int]$w.count; bytes = $b; riskLevel = 'medium'; regen = 'auto'; regenHint = 'Mở lại ứng dụng khi cần'
                    why = ('{0}. Đang giữ khoảng {1} RAM.' -f $what, (Format-RgSizeVi $b))
                    impact = 'Việc chưa lưu trong ứng dụng này sẽ mất nếu bạn đóng mà chưa lưu'
                    auto = 'ask'; cumBytes = $cum; reachesGoal = $reach; agent = $null
                }
            }
            # Hai bước cùng tiêu đề (vd. "Đóng Trình duyệt" cho msedge và msedgewebview2): thêm phần đuôi của khoá workload để người dùng phân biệt được.
            $dupT = @{}; foreach ($rs in $rsteps) { $dupT[[string]$rs.title] = 1 + [int]$dupT[[string]$rs.title] }
            foreach ($rs in $rsteps) {
                if ($dupT[[string]$rs.title] -gt 1) { $tail = ([string]$rs.workload -split '\|')[-1]; if ($tail -and ([string]$rs.title) -notmatch [regex]::Escape($tail)) { $rs.title = ('{0} ({1})' -f $rs.title, $tail) } }
            }
            $groups += [pscustomobject]@{ rank = [int]$stateRank[$rState]; idx = $gIdx; steps = @($rsteps) }; $gIdx++
            $afterAvail = $avail + $cum / 1GB
            $afterPlan += [ordered]@{ resource = 'ram'; drive = 'RAM'; freeGB = [math]::Round($afterAvail, 1); state = (Get-RgRamState $afterAvail $Cfg); shortBytes = [long][math]::Max(0L, [long]($need - $cum))
                beforeBytes = [long]($avail * 1GB); afterBytes = [long]($afterAvail * 1GB); stateBefore = $rState; stateAfter = (Get-RgRamState $afterAvail $Cfg) }
        }
    }
    foreach ($g_ in @($groups | Sort-Object @{ Expression = { $_.rank }; Descending = $true }, @{ Expression = { $_.idx } })) { $steps += @($g_.steps) }
    if ($goals.Count -gt 1) { $gi = @(0..($goals.Count - 1) | Sort-Object @{ Expression = { $stateRank[[string]$goals[$_].state] }; Descending = $true }, @{ Expression = { $_ } }); $goals = @($gi | ForEach-Object { $goals[$_] }) }
    $revBytes = 0L; foreach ($r in $reviewItems) { $revBytes += [long]$r.sizeBytes }
    return [ordered]@{
        generatedUtc = $Now.ToString('o'); candidatesUtc = $(if ($candUtc) { $candUtc.ToString('o') } else { $null }); stale = $stale
        goals = $goals; steps = $steps
        review = [ordered]@{ count = $reviewItems.Count; bytes = $revBytes; keys = @($reviewItems | ForEach-Object { [string]$_.key }) }
        afterPlan = $afterPlan; beyond = $beyond
    }
}
