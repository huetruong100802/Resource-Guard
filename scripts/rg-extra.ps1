# rg-extra.ps1 - ứng viên mở rộng (repo/workspace lâu không dùng, mục dung lượng lớn, ứng dụng) + nén zip tại chỗ trước khi xoá + giải nén.
# Dot-source từ rg-common.ps1 (không chạy trực tiếp). Tương thích Windows PowerShell 5.1 và PowerShell 7+.
# Thông điệp máy-đọc (reasons, blocker) viết bằng tiếng Anh ASCII.

$script:RgArchivableKinds = @('stale-repo', 'large-item')
# Thư mục sinh lại được: không tính vào "hoạt động" của repo (chỉ tính vào dung lượng).
$script:RgRepoSkipDirs = @('node_modules', 'bin', 'obj', '.git', '.vs', '.angular', '.nx', '.gradle')

function Test-RgArchivable([string]$Kind) { return ($script:RgArchivableKinds -contains $Kind) }

function Get-RgGitExe {
    $g = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    return $null
}

# ---------- Repo / workspace lâu không dùng ----------

# Thư mục chứa '.git' (là thư mục). Không đi vào trong repo đã tìm thấy, không đi xuyên junction/symlink.
function Find-RgGitRepos([string[]]$Roots, [int]$MaxDepth) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $stack.Push(@($root, 0))
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop(); $dir = [string]$cur[0]; $depth = [int]$cur[1]
            if (Test-Path -LiteralPath (Join-Path $dir '.git') -PathType Container) { [void]$out.Add($dir); continue }
            if ($depth -ge $MaxDepth) { continue }
            try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
            foreach ($s in $subs) {
                $leaf = [IO.Path]::GetFileName($s)
                if ($script:RgRepoSkipDirs -contains $leaf) { continue }
                try { $attr = [IO.File]::GetAttributes($s) } catch { continue }
                if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push(@($s, ($depth + 1)))
            }
        }
    }
    return @($out)
}

# Hoạt động = thời điểm GHI mới nhất của file nguồn (bỏ node_modules/bin/obj/.git...). Thoát sớm khi gặp file mới hơn $CutoffUtc.
# bytes = tổng dung lượng (kể cả thư mục bỏ qua) chỉ đầy đủ khi fresh = $false.
function Get-RgRepoActivity([string]$Path, [datetime]$CutoffUtc) {
    $bytes = 0L; $newest = [datetime]::MinValue
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($Path, $false))
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop(); $d = [string]$cur[0]; $skip = [bool]$cur[1]
        try {
            foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) {
                    $stack.Push(@($e.FullName, ($skip -or ($script:RgRepoSkipDirs -contains $e.Name)))); continue
                }
                $bytes += $e.Length
                if (-not $skip) {
                    $w = $e.LastWriteTimeUtc
                    if ($w -gt $newest) { $newest = $w }
                    if ($newest -ge $CutoffUtc) { return [pscustomobject]@{ fresh = $true; newestUtc = $newest; bytes = $bytes } }
                }
            }
        } catch { }
    }
    return [pscustomobject]@{ fresh = $false; newestUtc = $newest; bytes = $bytes }
}

# Xoá repo chỉ an toàn nếu mọi thứ còn có bản ở remote: không thay đổi chưa commit, không stash, không commit chưa push (mọi nhánh).
# Không xác minh được (không có git, git lỗi) => coi như KHÔNG an toàn.
function Get-RgGitState([string]$RepoPath) {
    $git = Get-RgGitExe
    if (-not $git) { return [pscustomobject]@{ safe = $false; reason = 'git is not installed; cannot verify the repo state' } }
    $old = $env:GIT_TERMINAL_PROMPT; $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $st = & $git --no-optional-locks -C $RepoPath status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ safe = $false; reason = 'git could not read the repo; cannot verify its state' } }
        if (@($st).Count -gt 0) { return [pscustomobject]@{ safe = $false; reason = 'has uncommitted or untracked changes' } }
        $sh = & $git --no-optional-locks -C $RepoPath stash list 2>$null
        if (@($sh).Count -gt 0) { return [pscustomobject]@{ safe = $false; reason = 'has stashed changes' } }
        $un = & $git --no-optional-locks -C $RepoPath log --branches --not --remotes -n 1 --format=%h 2>$null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ safe = $false; reason = 'git could not read the history; cannot verify its state' } }
        if (@($un).Count -gt 0) { return [pscustomobject]@{ safe = $false; reason = 'has commits that are not on any remote (no backup elsewhere)' } }
        return [pscustomobject]@{ safe = $true; reason = '' }
    } catch {
        return [pscustomobject]@{ safe = $false; reason = 'git failed; cannot verify the repo state' }
    } finally { $env:GIT_TERMINAL_PROMPT = $old }
}

function Test-RgContainsScripts([string]$RepoPath) {   # đừng bao giờ đề xuất xoá repo chứa chính tool này
    $r = $RepoPath.TrimEnd('\') + '\'
    return $script:RgScriptsDir.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RgStaleRepoCandidates($Cfg) {
    $items = @()
    $c = $Cfg.cleanup
    if (-not $c.staleRepo) { return $items }
    $days = [int]$c.staleRepo.minInactiveDays; $minBytes = [long]$c.staleRepo.minMB * 1MB
    $now = (Get-Date).ToUniversalTime(); $cutoff = $now.AddDays(-$days)
    $roots = @(Get-RgWorkspaceRoots $c)
    foreach ($repo in (Find-RgGitRepos $roots ([int]$c.maxDepth))) {
        if (Test-RgContainsScripts $repo) { continue }
        $act = Get-RgRepoActivity $repo $cutoff
        if ($act.fresh) { continue }
        if ($act.bytes -lt $minBytes) { continue }
        $ageDays = [math]::Floor(($now - $act.newestUtc).TotalDays)
        $gs = Get-RgGitState $repo
        if ($gs.safe) {
            $items += New-RgItem -Kind 'stale-repo' -Action 'delete' -Level 2 -Path $repo -SizeBytes $act.bytes -NewestUtc (ConvertTo-RgStamp $act.newestUtc) -AgeDays $ageDays `
                -Reason "repo with no source change for $ageDays days; everything is on a remote (can be cloned again). Git-ignored files such as .env are NOT on the remote" `
                -Risk 'medium: zip it first to keep ignored files (restorable from the zip)'
        } else {
            $items += New-RgItem -Kind 'stale-repo' -Action 'report' -Level 3 -Path $repo -SizeBytes $act.bytes -NewestUtc (ConvertTo-RgStamp $act.newestUtc) -AgeDays $ageDays `
                -Reason "repo with no source change for $ageDays days, but it $($gs.reason)" -Risk 'protected: report only'
        }
    }
    return $items
}

# ---------- Mục dung lượng lớn / ứng dụng ----------

function Get-RgLargeItemCandidates($Cfg) {
    $items = @()
    $c = $Cfg.cleanup.largeItem
    if (-not $c) { return $items }
    $days = [int]$c.minInactiveDays; $minBytes = [long]$c.minMB * 1MB
    $now = (Get-Date).ToUniversalTime(); $cutoff = $now.AddDays(-$days)
    foreach ($rootRaw in @($c.roots)) {
        $root = (Expand-RgPath ([string]$rootRaw)).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        if (Test-RgReparse $root) { continue }
        foreach ($e in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.PSIsContainer) {
                $st = Get-RgDirStats $e.FullName
                $size = $st.bytes; $newest = $st.newestUtc
                if ($e.LastWriteTimeUtc -gt $newest) { $newest = $e.LastWriteTimeUtc }
            } else {
                $size = $e.Length; $newest = $e.LastWriteTimeUtc
                if ($e.LastAccessTimeUtc -gt $newest) { $newest = $e.LastAccessTimeUtc }
            }
            if ($size -lt $minBytes -or $newest -ge $cutoff) { continue }
            $ageDays = [math]::Floor(($now - $newest).TotalDays)
            $items += New-RgItem -Kind 'large-item' -Action 'delete' -Level 2 -Path $e.FullName -SizeBytes $size -NewestUtc (ConvertTo-RgStamp $newest) -AgeDays $ageDays `
                -Reason "large item ($([math]::Round($size / 1MB)) MB) untouched for $ageDays days in $([IO.Path]::GetFileName($root))" -Risk 'medium: permanent unless you zip it first'
        }
    }
    return $items
}

function Get-RgAppCandidates($Cfg) {
    $items = @()
    $c = $Cfg.cleanup.apps
    if (-not $c) { return $items }
    $days = [int]$c.minInactiveDays; $minBytes = [long]$c.minMB * 1MB
    $now = (Get-Date).ToUniversalTime(); $cutoff = $now.AddDays(-$days)
    foreach ($rootRaw in @($c.roots)) {
        $root = (Expand-RgPath ([string]$rootRaw)).TrimEnd('\')
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $skip = $false
            foreach ($pat in @($c.exclude)) { if ($e.Name -like $pat) { $skip = $true; break } }
            if ($skip) { continue }
            $st = Get-RgDirStats $e.FullName
            if ($st.bytes -lt $minBytes) { continue }
            $newest = $st.newestUtc; if ($e.LastWriteTimeUtc -gt $newest) { $newest = $e.LastWriteTimeUtc }
            if ($newest -ge $cutoff) { continue }
            $ageDays = [math]::Floor(($now - $newest).TotalDays)
            $items += New-RgItem -Kind 'app' -Action 'report' -Level 3 -Path $e.FullName -SizeBytes $st.bytes -NewestUtc (ConvertTo-RgStamp $newest) -AgeDays $ageDays `
                -Reason "installed app folder with no file written for $ageDays days; uninstall it from Windows Settings > Apps (never delete the folder by hand)" -Risk 'protected: report only'
        }
    }
    return $items
}

# ---------- Nén zip tại chỗ ----------

function Get-RgArchiveManifest([string]$Path) {
    $files = New-Object 'System.Collections.Generic.List[object]'
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $bytes = 0L; $reparse = $false
    $base = $Path.TrimEnd('\') + '\'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path.TrimEnd('\'))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reparse = $true; continue }
            $rel = $e.FullName.Substring($base.Length)
            if ($e -is [IO.DirectoryInfo]) { [void]$dirs.Add($rel); $stack.Push($e.FullName) }
            else { [void]$files.Add([pscustomobject]@{ rel = $rel; len = [long]$e.Length; ticks = $e.LastWriteTimeUtc.Ticks }); $bytes += $e.Length }
        }
    }
    return [pscustomobject]@{ files = $files; dirs = $dirs; bytes = $bytes; reparse = $reparse }
}

function Get-RgArchivesPath { return (Join-Path (Initialize-RgHome) 'state\archives.json') }

function Read-RgArchives {
    $p = Get-RgArchivesPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try { return @(ConvertFrom-Json (Read-RgFileShared $p) | ForEach-Object { $_ }) } catch { return @() }   # ForEach-Object: PS 5.1 không tự bung mảng JSON
}

function Add-RgArchiveRecord($Rec) {
    $all = @(Read-RgArchives) + @($Rec)
    Write-RgFileAtomic (Get-RgArchivesPath) (ConvertTo-Json -InputObject @($all) -Depth 4 -Compress)
}

function Set-RgArchiveRestored([string]$Id) {
    $all = @(Read-RgArchives)
    foreach ($a in $all) { if ($a.id -eq $Id) { $a | Add-Member -NotePropertyName restoredUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force } }
    Write-RgFileAtomic (Get-RgArchivesPath) (ConvertTo-Json -InputObject @($all) -Depth 4 -Compress)
}

# Nén $Path thành <cha>\<tên>.zip (entry gốc là tên thư mục để giải nén ra đúng chỗ cũ), KIỂM TRA, rồi mới trả ok.
# Không bao giờ xoá gì. Thất bại ở bất kỳ bước nào => xoá file zip dang dở, trả ok = $false, dữ liệu gốc nguyên vẹn.
function New-RgArchive {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $fail = { param($m) return [pscustomobject]@{ ok = $false; error = $m } }
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    $parent = Split-Path $Path -Parent; $leaf = Split-Path $Path -Leaf
    $zip = Join-Path $parent ($leaf + '.zip')
    if (Test-Path -LiteralPath $zip) { $zip = Join-Path $parent ("{0}.{1}.zip" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $tmp = $zip + '.partial'
    try {
        if ($isDir) { $man = Get-RgArchiveManifest $Path }
        else {
            $fi = New-Object IO.FileInfo($Path)
            $man = [pscustomobject]@{ files = @([pscustomobject]@{ rel = $leaf; len = [long]$fi.Length; ticks = $fi.LastWriteTimeUtc.Ticks }); dirs = @(); bytes = [long]$fi.Length; reparse = $false }
        }
        if ($man.reparse) { return (& $fail 'contains a junction/symlink; refusing to archive it') }
        try {
            $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($parent))
            if ($drive.AvailableFreeSpace -lt ([long]($man.bytes * 1.02) + 64MB)) { return (& $fail 'not enough free space next to the item for the zip') }
        } catch { }
        $rootName = if ($isDir) { $leaf } else { $null }
        $fs = [IO.File]::Open($tmp, 'CreateNew', 'ReadWrite', 'None')
        try {
            $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                if ($isDir) {
                    [void]$za.CreateEntry($leaf + '/')
                    foreach ($dr in $man.dirs) { [void]$za.CreateEntry($leaf + '/' + $dr.Replace('\', '/') + '/') }
                }
                foreach ($f in $man.files) {
                    $src = if ($isDir) { Join-Path $Path $f.rel } else { $Path }
                    $name = if ($isDir) { $leaf + '/' + $f.rel.Replace('\', '/') } else { $leaf }
                    $in = [IO.File]::Open($src, 'Open', 'Read', 'Read')   # file đang được ghi bởi tiến trình khác => lỗi => huỷ
                    try {
                        $en = $za.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                        try { $en.LastWriteTime = New-Object DateTimeOffset ((New-Object DateTime ($f.ticks, 'Utc'))) } catch { }
                        $o = $en.Open()
                        try { $in.CopyTo($o) } finally { $o.Dispose() }
                    } finally { $in.Dispose() }
                }
            } finally { $za.Dispose() }
        } finally { $fs.Dispose() }

        # kiểm tra: mọi file đều có entry cùng kích thước và đọc giải nén được đủ số byte
        $rs = [IO.File]::Open($tmp, 'Open', 'Read', 'Read')
        try {
            $zr = New-Object IO.Compression.ZipArchive($rs, [IO.Compression.ZipArchiveMode]::Read, $false)
            try {
                $byName = @{}
                foreach ($en in $zr.Entries) { if (-not $en.FullName.EndsWith('/')) { $byName[$en.FullName] = $en } }
                if ($byName.Count -ne $man.files.Count) { throw 'verification: entry count differs from the source file count' }
                $buf = New-Object byte[] (1MB)
                foreach ($f in $man.files) {
                    $name = if ($isDir) { $leaf + '/' + $f.rel.Replace('\', '/') } else { $leaf }
                    $en = $byName[$name]
                    if (-not $en) { throw "verification: missing entry $name" }
                    if ($en.Length -ne $f.len) { throw "verification: size mismatch for $name" }
                    $s = $en.Open(); $n = 0L
                    try { while (($r = $s.Read($buf, 0, $buf.Length)) -gt 0) { $n += $r } } finally { $s.Dispose() }
                    if ($n -ne $f.len) { throw "verification: unreadable data for $name" }
                }
            } finally { $zr.Dispose() }
        } finally { $rs.Dispose() }

        # nguồn không được đổi trong lúc nén (nếu không, xoá nguồn sẽ mất phần mới)
        if ($isDir) {
            $man2 = Get-RgArchiveManifest $Path
            $a = @{}; foreach ($f in $man.files) { $a[$f.rel] = "$($f.len)|$($f.ticks)" }
            $same = ($man2.files.Count -eq $man.files.Count) -and ($man2.dirs.Count -eq $man.dirs.Count) -and (-not $man2.reparse)
            if ($same) { foreach ($f in $man2.files) { if ($a[$f.rel] -ne "$($f.len)|$($f.ticks)") { $same = $false; break } } }
            if (-not $same) { throw 'the source changed while it was being archived' }
        }
        [IO.File]::Move($tmp, $zip)
        $zb = (New-Object IO.FileInfo($zip)).Length
        return [pscustomobject]@{ ok = $true; zip = $zip; files = $man.files.Count; bytes = $man.bytes; zipBytes = [long]$zb; error = '' }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return (& $fail ("{0} (rg-extra.ps1:{1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber))
    }
}

# Giải nén một bản do tool tạo về ĐÚNG chỗ cũ. Chỉ nhận id trong archives.json; không ghi đè gì có sẵn; chống zip-slip.
function Restore-RgArchive([string]$Id) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $rec = @(Read-RgArchives | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $rec) { throw 'Không tìm thấy bản nén này.' }
    $zip = [string]$rec.zip; $orig = [string]$rec.original
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'File zip không còn tồn tại.' }
    if (Test-Path -LiteralPath $orig) { throw 'Vị trí cũ đã có dữ liệu; không ghi đè. Đổi tên hoặc xoá nó trước.' }
    $parent = Split-Path $orig -Parent; $leaf = Split-Path $orig -Leaf
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Thư mục cha của vị trí cũ không còn tồn tại.' }
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($parent))
        if ($drive.AvailableFreeSpace -lt ([long]$rec.bytes + 64MB)) { throw 'Không đủ dung lượng trống để giải nén.' }
    } catch [System.Management.Automation.RuntimeException] { throw } catch { }
    $isDirRec = -not [bool]$rec.isFile
    $base = $parent.TrimEnd('\') + '\'
    $rs = [IO.File]::Open($zip, 'Open', 'Read', 'Read')
    try {
        $zr = New-Object IO.Compression.ZipArchive($rs, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            foreach ($en in $zr.Entries) {
                $target = [IO.Path]::GetFullPath((Join-Path $parent $en.FullName.Replace('/', '\')))
                $okPath = $target.Equals($orig.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($orig.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
                if (-not $okPath) { throw "Entry không an toàn trong zip: $($en.FullName)" }
            }
            try {
                foreach ($en in $zr.Entries) {
                    $target = [IO.Path]::GetFullPath((Join-Path $parent $en.FullName.Replace('/', '\')))
                    if ($en.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
                    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($en, $target, $false)
                }
            } catch {
                if (Test-Path -LiteralPath $orig) { [void](Remove-RgTree -Path $orig) }   # dọn phần dang dở để lần sau thử lại được
                throw
            }
        } finally { $zr.Dispose() }
    } finally { $rs.Dispose() }
    Set-RgArchiveRestored $Id
    Write-RgLog 'archive-restored' ([ordered]@{ id = $Id; original = $orig })
    return $rec
}
