# rg-assistant.ps1 - trợ lý hiểu máy (plan-automation D1-D3 + dữ liệu cho D5). Dot-source từ rg-common.ps1; không chạy trực tiếp.
#   D1 kiểm kê: chỉ METADATA (đường dẫn, kích thước, mtime, atime, đuôi file, cờ "tải từ web"), không đọc nội dung file, không còn ngưỡng 500 MB.
#   D2 cụm tất định (không AI): gom theo (thư mục cha, họ file, bậc tuổi) -> clusterId ổn định, nhãn dễ đọc.
#   D3 verdict: luật tất định trả lời được MỌI cụm khi vắng `claude`; agent (nếu có) chỉ thay đổi verdict qua bộ lọc an toàn (ConvertTo-RgSafeVerdicts).
# Bất biến: file cá nhân KHÔNG BAO GIỜ tự xoá; cụm "góc khuất" (AppData) chỉ báo cáo; agent chỉ đề xuất, UI chỉ gửi clusterId, server tự giải ra đường dẫn.

$script:RgFamilyOf = @{}
$script:RgFamilyLabel = [ordered]@{ sheet = 'bảng tính'; doc = 'tài liệu'; slide = 'bài trình chiếu'; image = 'ảnh'; video = 'video'; audio = 'âm thanh'; archive = 'file nén'
    installer = 'bộ cài'; database = 'cơ sở dữ liệu'; backup = 'bản sao lưu'; code = 'mã nguồn'; temp = 'file tạm'; other = 'file khác' }
foreach ($pair in @(
        @('sheet', 'xls xlsx xlsm csv ods'), @('doc', 'doc docx pdf txt rtf md odt'), @('slide', 'ppt pptx odp'),
        @('image', 'jpg jpeg png gif bmp webp heic svg tif tiff'), @('video', 'mp4 mkv avi mov wmv webm'), @('audio', 'mp3 wav flac aac m4a ogg'),
        @('archive', 'zip rar 7z tar gz tgz bz2 xz'), @('installer', 'exe msi msix appx iso'), @('database', 'db sqlite sqlite3 mdf ldf accdb'),
        @('backup', 'bak old orig'), @('code', 'cs js ts py java cpp h json xml sln csproj ps1 sql'), @('temp', 'tmp log temp crdownload part'))) {
    foreach ($x in ($pair[1] -split ' ')) { $script:RgFamilyOf[$x] = $pair[0] }
}
# Họ file mà việc xoá thẳng KHÔNG BAO GIỜ được đề xuất (tối đa là nén có kiểm tra): file cá nhân/dữ liệu người dùng.
$script:RgPersonalFamilies = @('sheet', 'doc', 'slide', 'image', 'video', 'audio', 'code', 'database', 'backup', 'archive', 'other')

function Get-RgFileFamily([string]$Ext) {
    $e = ([string]$Ext).TrimStart('.').ToLowerInvariant()
    if ($script:RgFamilyOf.ContainsKey($e)) { return $script:RgFamilyOf[$e] }
    return 'other'
}

function ConvertTo-RgEpoch($Utc) { return [long]([DateTimeOffset]([datetime]$Utc).ToUniversalTime()).ToUnixTimeSeconds() }

# ---------- D1: kiểm kê ----------

function Get-RgInventoryConfig($Cfg) {
    $p = $env:USERPROFILE
    $o = [ordered]@{
        roots = @("$p\Downloads", "$p\Documents", "$p\Desktop"); hiddenRoots = @("$env:LOCALAPPDATA", "$env:APPDATA")
        hiddenExt = @('db', 'sqlite', 'sqlite3', 'bak', 'mdf', 'ldf'); hiddenMinMB = 1.0; hiddenMaxDepth = 5; maxDepth = 12
        maxFiles = 40000; maxSeconds = 90.0; minClusterFiles = 3; minClusterMB = 50.0
        keepRecentDays = 30; compressAfterDays = 90; installerCleanAfterDays = 30; tempCleanAfterDays = 14
    }
    try {
        if ($Cfg -and $Cfg.PSObject.Properties['inventory'] -and $Cfg.inventory) {
            $c = $Cfg.inventory
            foreach ($k in @('roots', 'hiddenRoots', 'hiddenExt')) { $q = $c.PSObject.Properties[$k]; if ($q -and $null -ne $q.Value) { $o[$k] = @($q.Value | ForEach-Object { [string]$_ } | Where-Object { $_ }) } }
            foreach ($k in @('hiddenMinMB', 'hiddenMaxDepth', 'maxDepth', 'maxFiles', 'maxSeconds', 'minClusterFiles', 'minClusterMB', 'keepRecentDays', 'compressAfterDays', 'installerCleanAfterDays', 'tempCleanAfterDays')) {
                $q = $c.PSObject.Properties[$k]; if ($q -and $null -ne $q.Value -and [double]$q.Value -ge 0) { $o[$k] = [double]$q.Value }
            }
        }
    } catch { }
    $o.roots = @($o.roots | ForEach-Object { (Expand-RgPath $_).TrimEnd('\') } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
    $o.hiddenRoots = @($o.hiddenRoots | ForEach-Object { (Expand-RgPath $_).TrimEnd('\') } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
    $o.hiddenExt = @($o.hiddenExt | ForEach-Object { $_.TrimStart('.').ToLowerInvariant() })
    return [pscustomobject]$o
}

$script:RgAtimeEnabled = $null
function Test-RgAtimeEnabled {
    if ($null -ne $script:RgAtimeEnabled) { return [bool]$script:RgAtimeEnabled }
    $v = $true
    try { $t = (& fsutil behavior query disablelastaccess 2>$null | Out-String); if ($t -match 'DISABLED') { $v = $false } } catch { }
    $script:RgAtimeEnabled = $v
    return $v
}

# File có luồng NTFS Zone.Identifier (tải từ web) không? GetFileAttributesW không kiểm tra định dạng đường dẫn như .NET nên hỏi được "path:Zone.Identifier".
function Initialize-RgStreamProbe {
    if ('RgStreamProbe' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RgStreamProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFileAttributesW(string lpFileName);
    public static bool Has(string path, string stream) { return GetFileAttributesW(path + ":" + stream) != 0xFFFFFFFF; }
}
'@
        return $true
    } catch { return $false }
}

# Kiểm kê metadata. Trả { version; builtUtc; seconds; atimeEnabled; truncated; roots[{path,label,hidden,files,bytes,truncated}]; files[[rootIdx, relPath, size, mtimeEpoch, atimeEpoch, web]] }.
function Invoke-RgInventoryBuild {
    param($Cfg = $null)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $ic = Get-RgInventoryConfig $Cfg
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $roots = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $skipDirs = @('node_modules', '.git', '.vs', 'bin', 'obj', '$recycle.bin', 'system volume information')
    $hiddenSkip = @('cache', 'code cache', 'gpucache', 'temp', 'tmp', 'node_modules', '.git', 'crashpad', 'logs', 'packages')
    $web = Initialize-RgStreamProbe
    $total = 0; $truncated = $false
    $specs = @(); foreach ($r in $ic.roots) { $specs += [pscustomobject]@{ path = $r; hidden = $false } }; foreach ($r in $ic.hiddenRoots) { $specs += [pscustomobject]@{ path = $r; hidden = $true } }
    foreach ($sp in $specs) {
        $idx = $roots.Count
        $rec = [pscustomobject][ordered]@{ path = $sp.path; label = [IO.Path]::GetFileName($sp.path); hidden = [bool]$sp.hidden; files = 0; bytes = 0L; truncated = $false }
        [void]$roots.Add($rec)
        $isDl = ($rec.label -ieq 'Downloads')
        $maxDepth = if ($sp.hidden) { [int]$ic.hiddenMaxDepth } else { [int]$ic.maxDepth }
        $stack = New-Object 'System.Collections.Generic.Stack[object]'; $stack.Push(@($sp.path, 0))
        while ($stack.Count -gt 0) {
            if ($total -ge [int]$ic.maxFiles -or $sw.Elapsed.TotalSeconds -ge [double]$ic.maxSeconds) { $rec.truncated = $true; $truncated = $true; break }
            $cur = $stack.Pop(); $dir = [string]$cur[0]; $depth = [int]$cur[1]
            if (-not $sp.hidden -and (Test-Path -LiteralPath (Join-Path $dir '.git') -PathType Container)) { continue }   # repo: đã có nhóm repo cũ riêng
            try {
                foreach ($e in (New-Object IO.DirectoryInfo($dir)).EnumerateFileSystemInfos()) {
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($e -is [IO.DirectoryInfo]) {
                        $nl = $e.Name.ToLowerInvariant()
                        if ($depth -ge $maxDepth -or $skipDirs -contains $nl -or ($sp.hidden -and $hiddenSkip -contains $nl)) { continue }
                        $stack.Push(@($e.FullName, ($depth + 1))); continue
                    }
                    $ext = $e.Extension.TrimStart('.').ToLowerInvariant()
                    if ($sp.hidden -and (($ic.hiddenExt -notcontains $ext) -or $e.Length -lt ([double]$ic.hiddenMinMB * 1MB))) { continue }
                    $rel = $e.FullName.Substring($sp.path.Length).TrimStart('\')
                    $wb = 0; if ($isDl -and $web -and [RgStreamProbe]::Has($e.FullName, 'Zone.Identifier')) { $wb = 1 }
                    [void]$files.Add(@($idx, $rel, [long]$e.Length, (ConvertTo-RgEpoch $e.LastWriteTimeUtc), (ConvertTo-RgEpoch $e.LastAccessTimeUtc), $wb))
                    $rec.files++; $rec.bytes += [long]$e.Length; $total++
                }
            } catch { }
        }
    }
    return [pscustomobject][ordered]@{ version = 1; builtUtc = (Get-Date).ToUniversalTime().ToString('o'); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        atimeEnabled = (Test-RgAtimeEnabled); truncated = $truncated; roots = @($roots.ToArray()); files = $files }
}

function Get-RgStatePath([string]$Name) { return (Join-Path (Initialize-RgHome) ('state\' + $Name)) }
function Save-RgInventory($Inv) { Write-RgFileAtomic (Get-RgStatePath 'inventory.json') (ConvertTo-Json -InputObject $Inv -Depth 5 -Compress) }
function Read-RgInventory {
    $p = Get-RgStatePath 'inventory.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json (Read-RgFileShared $p)) } catch { Write-RgLog 'inventory-read-error' @{ error = [string]$_.Exception.Message }; return $null }
}

# ---------- D2: cụm tất định ----------

function Get-RgAgeBucket([int]$AgeDays) {
    if ($AgeDays -lt 30) { return 'recent' }
    if ($AgeDays -lt 90) { return 'month' }
    if ($AgeDays -lt 365) { return 'quarter' }
    return 'year'
}

# Gom file của kiểm kê thành cụm. Bỏ file nằm trong vùng bảo vệ (người dùng hoặc agent giữ) và thư mục có đoạn đường dẫn trong cfg.protected.segments.
# -KeepFiles: giữ danh sách đường dẫn đầy đủ của từng cụm (chỉ dùng phía server để giải clusterId -> file; KHÔNG đưa ra API/agent).
# Schema: { clusterId; label; root; rootLabel; kind; ext; count; totalBytes; oldestMtime; newestMtime; ageDays; ageBucket; sample[<=5]; protected=$false; hidden; reportOnly; webCount; verdictKey }
function New-RgClusters {
    param($Inv, $Cfg = $null, $Policy = $null, [switch]$KeepFiles)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $ic = Get-RgInventoryConfig $Cfg
    $nowE = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $atime = [bool]$Inv.atimeEnabled
    $segs = @(); try { $segs = @($Cfg.protected.segments | ForEach-Object { ([string]$_).ToLowerInvariant() }) } catch { }
    $canProt = [bool](Get-Command Test-RgPathProtected -ErrorAction SilentlyContinue)
    if ($canProt -and -not $Policy) { $Policy = Get-RgPolicy }
    $protCache = @{}
    $groups = @{}; $skippedProtected = 0
    $rootsArr = @($Inv.roots)
    foreach ($f in $Inv.files) {
        $ri = [int]$f[0]; $root = $rootsArr[$ri]
        $abs = ([string]$root.path) + '\' + ([string]$f[1])
        $parent = [IO.Path]::GetDirectoryName($abs)
        if (-not $protCache.ContainsKey($parent)) {
            $bad = $false
            foreach ($s in $parent.ToLowerInvariant().Split('\')) { if ($segs -contains $s) { $bad = $true; break } }
            if (-not $bad -and $canProt) { $bad = [bool](Test-RgPathProtected $parent $Policy) }
            $protCache[$parent] = $bad
        }
        if ($protCache[$parent]) { $skippedProtected++; continue }
        $ext = [IO.Path]::GetExtension($abs).TrimStart('.').ToLowerInvariant()
        $fam = Get-RgFileFamily $ext
        $m = [long]$f[3]; $idle = $m; if ($atime -and [long]$f[4] -gt $idle) { $idle = [long]$f[4] }
        $age = [int][math]::Max(0, [math]::Floor(($nowE - $idle) / 86400.0))
        $bucket = Get-RgAgeBucket $age
        $key = "$parent|$fam|$bucket|$([bool]$root.hidden)"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ parent = $parent; root = $root; fam = $fam; bucket = $bucket; count = 0; bytes = 0L; oldest = [long]::MaxValue; newest = 0L; exts = @{}; top = @(); web = 0; files = (New-Object System.Collections.ArrayList) }
        }
        $g = $groups[$key]
        $size = [long]$f[2]
        $g.count++; $g.bytes += $size
        if ($m -lt $g.oldest) { $g.oldest = $m }
        if ($idle -gt $g.newest) { $g.newest = $idle }
        if ($ext) { $g.exts[$ext] = 1 + [int]$g.exts[$ext] }
        if ([int]$f[5] -eq 1) { $g.web++ }
        if ($g.top.Count -lt 5) { $g.top += [pscustomobject]@{ n = [IO.Path]::GetFileName($abs); s = $size } }
        else { $min = ($g.top | Sort-Object s | Select-Object -First 1); if ($size -gt $min.s) { $g.top = @($g.top | Where-Object { [object]::ReferenceEquals($_, $min) -eq $false }) + [pscustomobject]@{ n = [IO.Path]::GetFileName($abs); s = $size } } }
        if ($KeepFiles) { [void]$g.files.Add($abs) }
    }
    $out = @(); $minorFiles = 0; $minorBytes = 0L
    foreach ($g in $groups.Values) {
        if ($g.count -lt [int]$ic.minClusterFiles -and $g.bytes -lt ([double]$ic.minClusterMB * 1MB)) { $minorFiles += $g.count; $minorBytes += $g.bytes; continue }
        $topExt = ($g.exts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $ext = if ($topExt) { [string]$topExt.Key } else { '' }
        $leaf = [IO.Path]::GetFileName($g.parent.TrimEnd('\')); if (-not $leaf) { $leaf = $g.parent }
        $famVi = [string]$script:RgFamilyLabel[$g.fam]
        $age = [int][math]::Max(0, [math]::Floor(($nowE - $g.newest) / 86400.0))
        $id = (Get-RgSha256 ("$($g.parent)|$($g.fam)|$($g.bucket)|$([bool]$g.root.hidden)")).Substring(0, 12)
        $sizeBucket = [int][math]::Floor([math]::Log([math]::Max(1.0, $g.bytes / 1MB), 2))
        $vk = (Get-RgSha256 ("$($g.parent)|$($g.fam)|$sizeBucket|$([math]::Floor($g.newest / 86400))")).Substring(0, 12)
        $label = "$($g.count) tệp $famVi" + $(if ($ext) { " ($ext)" } else { '' }) + " trong $leaf, " + (Format-RgSizeVi $g.bytes) + $(if ($age -ge 30) { ", chưa đụng $age ngày" } else { '' })
        $c = [ordered]@{ clusterId = $id; label = $label; root = $g.parent; rootLabel = $leaf; kind = $g.fam; ext = $ext; count = $g.count; totalBytes = $g.bytes
            oldestMtime = ([DateTimeOffset]::FromUnixTimeSeconds($g.oldest).UtcDateTime.ToString('o')); newestMtime = ([DateTimeOffset]::FromUnixTimeSeconds($g.newest).UtcDateTime.ToString('o'))
            ageDays = $age; ageBucket = $g.bucket; sample = @($g.top | Sort-Object s -Descending | ForEach-Object { $_.n }); protected = $false
            hidden = [bool]$g.root.hidden; reportOnly = [bool]$g.root.hidden; webCount = $g.web; verdictKey = $vk }
        if ($KeepFiles) { $c['files'] = @($g.files.ToArray()) }
        $out += [pscustomobject]$c
    }
    $script:RgClusterMinor = [pscustomobject]@{ files = $minorFiles; bytes = $minorBytes; protectedSkipped = $skippedProtected }
    return @($out | Sort-Object totalBytes -Descending)   # nơi gọi bọc @(...) để luôn có mảng (kể cả 0 hoặc 1 cụm)
}

# ---------- D3: verdict ----------

# Luật tất định: trả lời MỌI cụm, chạy được khi không có agent. Không bao giờ đề xuất xoá file cá nhân; tối đa là nén có kiểm tra.
function Get-RgRuleVerdict($Cluster, $Cfg) {
    $ic = Get-RgInventoryConfig $Cfg
    $age = [int]$Cluster.ageDays; $fam = [string]$Cluster.kind
    $v = { param($verdict, $reason, $conf) [pscustomobject]@{ clusterId = [string]$Cluster.clusterId; verdict = $verdict; reason = $reason; confidence = $conf; source = 'rule' } }
    if ([bool]$Cluster.reportOnly) { return (& $v 'keep' 'Dữ liệu ứng dụng ở góc khuất: chỉ báo cáo, Resource Guard không đụng tới.' 'high') }
    if ($age -lt [int]$ic.keepRecentDays) { return (& $v 'keep' "Mới dùng trong $([int]$ic.keepRecentDays) ngày gần đây." 'high') }
    if ($fam -eq 'installer' -and $age -ge [int]$ic.installerCleanAfterDays) {
        $conf = if ([int]$Cluster.webCount -ge [int]$Cluster.count) { 'high' } else { 'medium' }
        return (& $v 'clean' "Bộ cài đã tải, $age ngày chưa dùng; tải lại được từ nơi phát hành." $conf)
    }
    if ($fam -eq 'temp' -and $age -ge [int]$ic.tempCleanAfterDays) { return (& $v 'clean' "File tạm/đang tải dở, $age ngày chưa đụng tới." 'medium') }
    if (@('image', 'video', 'audio') -contains $fam) { return (& $v 'keep' 'Ảnh/video/âm thanh khó nén thêm; chỉ bạn quyết định chuyển hay xoá.' 'medium') }
    if ($fam -eq 'archive') { return (& $v 'keep' 'Đã là file nén; chỉ bạn quyết định giữ hay xoá.' 'medium') }
    if ($age -ge [int]$ic.compressAfterDays) { return (& $v 'compress' "Chưa đụng $age ngày: nén zip có kiểm tra để lấy lại chỗ, khôi phục được bất cứ lúc nào." 'medium') }
    return (& $v 'keep' "Mới $age ngày: chưa đến lúc nén." 'medium')
}

function Read-RgVerdictCache {
    $p = Get-RgStatePath 'verdicts.json'
    $c = @{}
    if (Test-Path -LiteralPath $p) {
        try { $j = ConvertFrom-Json (Read-RgFileShared $p); foreach ($pr in $j.items.PSObject.Properties) { $c[[string]$pr.Name] = $pr.Value } } catch { Write-RgLog 'verdict-cache-error' @{ error = [string]$_.Exception.Message } }
    }
    return $c
}

# Chỉ verdict của agent được nhớ (luật rẻ, tính lại mỗi lần). Khoá = verdictKey (thư mục, họ, bậc dung lượng, ngày sửa mới nhất): đổi nội dung thì tự hết hiệu lực.
function Save-RgVerdictCache($Cache) {
    $items = [ordered]@{}
    foreach ($e in ($Cache.GetEnumerator() | Sort-Object { [string]$_.Value.ts } -Descending | Select-Object -First 2000)) { $items[[string]$e.Key] = $e.Value }
    Write-RgFileAtomic (Get-RgStatePath 'verdicts.json') (ConvertTo-Json -InputObject ([ordered]@{ version = 1; items = $items }) -Depth 4 -Compress)
}

# Bộ lọc an toàn cho verdict do agent trả về. $Raw = [{ clusterId; verdict; reason; confidence }]. Trả { verdicts; dropped }.
#  - clusterId lạ bị loại (agent không bịa được cụm); verdict lạ bị loại.
#  - cụm báo cáo-thôi / họ file cá nhân: 'clean' hạ xuống 'compress', 'promote-auto' bị bỏ (agent không tự cấp quyền tự động cho nhóm mới).
function ConvertTo-RgSafeVerdicts($Raw, $Clusters, $Cfg) {
    $byId = @{}; foreach ($c in @($Clusters)) { $byId[[string]$c.clusterId] = $c }
    $out = @(); $dropped = 0
    foreach ($r in @($Raw)) {
        $c = $byId[[string]$r.clusterId]
        $vd = [string]$r.verdict
        if (-not $c -or @('keep', 'compress', 'clean', 'promote-auto') -notcontains $vd) { $dropped++; continue }
        $rule = Get-RgRuleVerdict $c $Cfg
        $reason = ([string]$r.reason -replace '[\x00-\x1f]', ' ').Trim()
        if ($env:USERPROFILE) { $reason = $reason.Replace($env:USERPROFILE, '~') }
        if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) }
        if (-not $reason) { $reason = $rule.reason }
        $conf = [string]$r.confidence; if (@('low', 'medium', 'high') -notcontains $conf) { $conf = 'low' }
        if ([bool]$c.reportOnly -or [bool]$c.protected) { $vd = 'keep'; $reason = $rule.reason; $conf = 'high' }
        elseif ($vd -eq 'promote-auto') { $vd = $rule.verdict; $reason = $rule.reason; $conf = $rule.confidence; $dropped++ }
        elseif ($vd -eq 'clean' -and $script:RgPersonalFamilies -contains [string]$c.kind) { $vd = 'compress' }
        elseif ($vd -eq 'compress' -and [int]$c.ageDays -lt [int](Get-RgInventoryConfig $Cfg).keepRecentDays) { $vd = 'keep'; $reason = $rule.reason }
        $out += [pscustomobject]@{ clusterId = [string]$c.clusterId; verdict = $vd; reason = $reason; confidence = $conf; source = 'agent' }
    }
    return [pscustomobject]@{ verdicts = @($out); dropped = $dropped }
}

# Verdict cho từng cụm: agent đã nhớ (còn mới, qua bộ lọc lại) nếu có, không thì luật. Gắn thêm: verdict, verdictReason, confidence, source, actionable, gainBytes.
function Add-RgClusterVerdicts($Clusters, $Cfg, $Cache = $null) {
    if ($null -eq $Cache) { $Cache = Read-RgVerdictCache }
    $cut = (Get-Date).ToUniversalTime().AddDays(-30)
    $out = @()
    foreach ($c in @($Clusters)) {
        $vd = Get-RgRuleVerdict $c $Cfg
        $hit = $Cache[[string]$c.verdictKey]
        if ($hit -and -not [bool]$c.reportOnly) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse([string]$hit.ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$ts) -and $ts.ToUniversalTime() -gt $cut) {
                $safe = ConvertTo-RgSafeVerdicts @([pscustomobject]@{ clusterId = $c.clusterId; verdict = $hit.verdict; reason = $hit.reason; confidence = $hit.confidence }) @($c) $Cfg
                if (@($safe.verdicts).Count -eq 1) { $vd = $safe.verdicts[0] }
            }
        }
        $act = (@('compress', 'clean') -contains $vd.verdict) -and -not [bool]$c.reportOnly -and -not [bool]$c.protected
        $gain = 0L
        if ($act) { $gain = if ($vd.verdict -eq 'clean') { [long]$c.totalBytes } else { [long]([double]$c.totalBytes * 0.5) } }   # nén: ước tính ~50%
        $o = [ordered]@{}; foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -ne 'files') { $o[$pr.Name] = $pr.Value } }
        $o['verdict'] = $vd.verdict; $o['verdictReason'] = $vd.reason; $o['confidence'] = $vd.confidence; $o['source'] = $vd.source; $o['actionable'] = $act; $o['gainBytes'] = $gain
        $out += [pscustomobject]$o
    }
    return $out
}

# ---------- Cụm bị ẩn tạm (người dùng bấm "Để sau") ----------
function Get-RgDismissed {
    $p = Get-RgStatePath 'assistant-dismissed.json'; $m = @{}
    if (Test-Path -LiteralPath $p) {
        try { $now = (Get-Date).ToUniversalTime(); foreach ($pr in (ConvertFrom-Json (Read-RgFileShared $p)).items.PSObject.Properties) { $t = [datetime]::Parse([string]$pr.Value, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime(); if ($t -gt $now) { $m[[string]$pr.Name] = $t } } } catch { }
    }
    return $m
}
function Add-RgDismissed([string]$ClusterId, [int]$Days = 30) {
    if ($ClusterId -notmatch '^[0-9a-f]{12}$') { return $false }
    $m = Get-RgDismissed; $m[$ClusterId] = (Get-Date).ToUniversalTime().AddDays($Days)
    $items = [ordered]@{}; foreach ($k in $m.Keys) { $items[$k] = $m[$k].ToString('o') }
    Write-RgFileAtomic (Get-RgStatePath 'assistant-dismissed.json') (ConvertTo-Json -InputObject ([ordered]@{ version = 1; items = $items }) -Compress)
    return $true
}

# ---------- Lượt quét: kiểm kê -> cụm -> lưu ----------
# state\inventory.json (đủ file, chỉ đọc bởi job) và state\clusters.json (nhỏ, cho UI). Trả bản tóm tắt.
function Invoke-RgAssistantScan {
    param($Cfg = $null)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $inv = Invoke-RgInventoryBuild $Cfg
    Save-RgInventory $inv
    $cl = @(New-RgClusters $inv $Cfg)
    $minor = $script:RgClusterMinor
    $sum = [ordered]@{ version = 1; builtUtc = $inv.builtUtc; seconds = $inv.seconds; atimeEnabled = $inv.atimeEnabled; truncated = $inv.truncated
        roots = @($inv.roots | ForEach-Object { [ordered]@{ label = $_.label; hidden = $_.hidden; files = $_.files; bytes = $_.bytes; truncated = $_.truncated } })
        fileCount = @($inv.files).Count; clusters = $cl; minor = $minor }
    Write-RgFileAtomic (Get-RgStatePath 'clusters.json') (ConvertTo-Json -InputObject $sum -Depth 6 -Compress)
    Write-RgLog 'assistant-scan' ([ordered]@{ files = $sum.fileCount; clusters = $cl.Count; seconds = $inv.seconds; truncated = $inv.truncated })
    return $sum
}

# ---------- Báo cáo (D5): đọc cụm đã lưu, kiểm lại bảo vệ NGAY BÂY GIỜ, gắn verdict ----------
function Get-RgAssistantReport {
    param($Cfg = $null)
    if (-not $Cfg) { $Cfg = Get-RgConfig }
    $p = Get-RgStatePath 'clusters.json'
    $evp = $null; try { $evp = Get-RgEvaluator $Cfg } catch { }
    $agent = [ordered]@{ available = [bool]$evp; provider = $(if ($evp) { [string]$evp.id } else { $null }); label = $(if ($evp) { [string]$evp.label } else { $null }); local = $(if ($evp) { [bool]$evp.local } else { $false }) }
    if (-not (Test-Path -LiteralPath $p)) { return [pscustomobject][ordered]@{ ok = $true; scanned = $false; agent = $agent; clusters = @(); summary = [ordered]@{} } }
    $raw = ConvertFrom-Json (Read-RgFileShared $p)
    $pol = $null; $canProt = [bool](Get-Command Test-RgPathProtected -ErrorAction SilentlyContinue)
    if ($canProt) { $pol = Get-RgPolicy }
    $dis = Get-RgDismissed
    $cl = @()
    foreach ($c in @($raw.clusters)) {
        if ($dis.ContainsKey([string]$c.clusterId)) { continue }
        if ($canProt -and (Test-RgPathProtected ([string]$c.root) $pol)) { $c.protected = $true }
        $cl += $c
    }
    $withV = @(Add-RgClusterVerdicts $cl $Cfg)
    foreach ($c in $withV) { [void]$c.PSObject.Properties.Remove('root') }   # UI chỉ cần nhãn + tên thư mục (rootLabel); đường dẫn đầy đủ ở lại phía server
    $ageH = Get-RgScanAgeHours ([string]$raw.builtUtc)
    $sum = [ordered]@{ compressBytes = 0L; cleanBytes = 0L; gainBytes = 0L; compress = 0; clean = 0; keep = 0 }
    foreach ($c in $withV) {
        $sum[[string]$c.verdict] = 1 + [int]$sum[[string]$c.verdict]
        if ($c.actionable) { if ($c.verdict -eq 'compress') { $sum.compressBytes += [long]$c.totalBytes } else { $sum.cleanBytes += [long]$c.totalBytes }; $sum.gainBytes += [long]$c.gainBytes }
    }
    return [pscustomobject][ordered]@{ ok = $true; scanned = $true; builtUtc = $raw.builtUtc; ageHours = $ageH; stale = (Test-RgScanStale ([string]$raw.builtUtc)); truncated = [bool]$raw.truncated
        atimeEnabled = [bool]$raw.atimeEnabled; fileCount = $raw.fileCount; roots = @($raw.roots); minor = $raw.minor; agent = $agent; clusters = $withV; summary = $sum }
}

# ---------- Payload cho agent: metadata cụm, KHÔNG đường dẫn đầy đủ, KHÔNG tên file ----------
# Ngân sách: tối đa $MaxClusters cụm (lớn nhất, chưa có verdict agent còn mới) và ~$MaxChars ký tự JSON.
function New-RgClusterAgentPayload {
    param($Clusters, $Cfg, [int]$MaxClusters = 40, [int]$MaxChars = 16000)
    $cache = Read-RgVerdictCache
    $cut = (Get-Date).ToUniversalTime().AddDays(-30)
    $need = @($Clusters | Where-Object {
            if ([bool]$_.reportOnly -or [bool]$_.protected) { return $false }
            $h = $cache[[string]$_.verdictKey]
            if (-not $h) { return $true }
            $ts = [datetime]::MinValue
            return -not ([datetime]::TryParse([string]$h.ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$ts) -and $ts.ToUniversalTime() -gt $cut)
        } | Sort-Object totalBytes -Descending | Select-Object -First $MaxClusters)
    $rows = @(); $len = 0
    foreach ($c in $need) {
        $row = [ordered]@{ clusterId = [string]$c.clusterId; family = [string]$c.kind; ext = [string]$c.ext; files = [int]$c.count; sizeMB = [math]::Round([double]$c.totalBytes / 1MB, 1)
            idleDays = [int]$c.ageDays; folder = [string]$c.rootLabel; downloadedFromWebPct = $(if ([int]$c.count -gt 0) { [int][math]::Round(100.0 * [int]$c.webCount / [int]$c.count) } else { 0 })
            ruleVerdict = [string](Get-RgRuleVerdict $c $Cfg).verdict }
        $j = (ConvertTo-Json -InputObject $row -Compress)
        if ($len + $j.Length -gt $MaxChars) { break }
        $len += $j.Length; $rows += $row
    }
    return [ordered]@{ generatedUtc = (Get-Date).ToUniversalTime().ToString('o'); clusters = $rows; omitted = ($need.Count - $rows.Count) }
}

# ---------- Thi hành một hành động trên MỘT cụm (dùng chung cho job UI và Invoke-RgAction) ----------
# Chỉ nhận clusterId + hành động. Đường dẫn do hàm này giải từ kiểm kê; mỗi tệp đi qua plan -> approve -> Invoke-RgApply
# (allowlist 'cluster-file' + revalidate + vùng bảo vệ + kiểm tệp đang được dùng + journal). Ném lỗi (tiếng Việt) khi bị từ chối.
#   compress: nén zip CÓ XÁC MINH cạnh từng tệp rồi mới xoá bản gốc. clean: xoá thẳng, chỉ cho họ không phải file cá nhân.
function Invoke-RgClusterAction {
    param([string]$ClusterId, [ValidateSet('compress', 'clean')][string]$Action, [string]$By = 'ui', [scriptblock]$OnProgress = $null)
    $say = { param($m) if ($OnProgress) { try { & $OnProgress $m } catch { } } }
    if ($ClusterId -notmatch '^[0-9a-f]{12}$') { throw 'clusterId không hợp lệ.' }
    $cfg = Get-RgConfig
    $inv = Read-RgInventory
    if (-not $inv) { throw 'Chưa kiểm kê; hãy quét lại trước.' }
    if (Test-RgScanStale ([string]$inv.builtUtc)) { throw 'Dữ liệu kiểm kê đã cũ; hãy quét lại trước khi thao tác.' }
    $policy = Get-RgPolicy
    $c = @(New-RgClusters $inv $cfg $policy -KeepFiles | Where-Object { $_.clusterId -eq $ClusterId }) | Select-Object -First 1
    if (-not $c) { throw 'Cụm không còn trong kiểm kê (đã đổi hoặc nằm trong vùng bảo vệ).' }
    if ([bool]$c.reportOnly) { throw 'Cụm này chỉ để báo cáo, Resource Guard không đụng tới.' }
    if ($Action -eq 'clean' -and ($script:RgPersonalFamilies -contains [string]$c.kind)) { throw 'File cá nhân không được xoá thẳng; chỉ có thể nén.' }
    $files = @($c.files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $capped = 0
    if ($files.Count -gt 200) { $capped = $files.Count - 200; $files = @($files | Select-Object -First 200) }
    $items = @(); $refused = @()
    foreach ($f in $files) {
        if (Test-RgPathProtected $f $policy) { $refused += [pscustomobject]@{ target = $f; reason = 'nằm trong vùng bảo vệ' }; continue }
        $fi = Get-Item -LiteralPath $f -Force
        $items += New-RgItem -Kind 'cluster-file' -Action 'delete' -Level 2 -Path $f -SizeBytes ([long]$fi.Length) -NewestUtc (ConvertTo-RgStamp $fi.LastWriteTimeUtc) `
            -Reason "assistant cluster $ClusterId ($($c.kind))" -Risk 'medium: personal file' -AgeDays ([int]$c.ageDays) -Archive ($Action -eq 'compress')
    }
    $results = @(); $freed = 0L; $planId = $null
    if ($items.Count -gt 0) {
        & $say "đang xử lý $($items.Count) tệp"
        $plan = New-RgPlan -Items $items
        $planId = $plan.planId
        $ids = @($plan.items | ForEach-Object { [int]$_.id })
        [void](Set-RgPlanApproval -PlanId $planId -ItemIds $ids -By $(if ($By -match ':') { $By } else { "$By`:$env:USERNAME" }))
        $res = Invoke-RgApply -PlanId $planId
        $freed = [long]$res.freedBytes
        $results = @($res.results | ForEach-Object { [pscustomobject]@{ key = (Get-RgSha256 ("cluster-file|" + [string]$_.target)).Substring(0, 12); kind = $_.kind; target = $_.target; outcome = $_.outcome; detail = $_.detail } })
    }
    $rec = [ordered]@{ finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); by = $By; planId = $planId; freedBytes = $freed; results = $results; refused = $refused; clusterId = $ClusterId; action = $Action; cappedFiles = $capped }
    Write-RgFileAtomic (Join-Path (Initialize-RgHome) 'state\cleanup-last.json') (ConvertTo-Json -InputObject $rec -Depth 6 -Compress)
    $done = @($results | Where-Object { $_.outcome -eq 'done' }).Count
    Write-RgLog 'assistant-act' ([ordered]@{ by = $By; clusterId = $ClusterId; action = $Action; planId = $planId; items = $results.Count; done = $done; refused = $refused.Count; freedBytes = $freed })
    $rec['done'] = $done
    return [pscustomobject]$rec
}
