# rg-scan.ps1 - quét nền, chạy ở process riêng (server không bị chặn). Chỉ ĐỌC, không xoá gì.
#   -Mode breakdown  : phân tích ổ đĩa theo nhóm nhân tố (C# đa luồng) -> state\scan-breakdown.json
#   -Mode candidates : danh sách ứng viên dọn dẹp (Get-RgCandidates)   -> state\scan-candidates.json
# Tiến độ: state\scan-<mode>.progress.json (đọc bởi server/UI).
[CmdletBinding()]
param([ValidateSet('breakdown', 'candidates')][string]$Mode = 'breakdown', [string]$Drive = 'C', [int]$Threads = 4)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
$stateDir = Join-Path (Initialize-RgHome) 'state'
$progPath = Join-Path $stateDir "scan-$Mode.progress.json"
$outPath = Join-Path $stateDir "scan-$Mode.json"
$started = Get-Date

function Write-Prog([string]$Status, [double]$Pct, [long]$Files = 0, [long]$Bytes = 0, [string]$Cur = '', [string]$Msg = '') {
    $o = [ordered]@{ mode = $Mode; pid = $PID; status = $Status; pct = [math]::Round($Pct, 1); files = $Files; bytes = $Bytes; current = $Cur; message = $Msg
        startedUtc = $started.ToUniversalTime().ToString('o'); updatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    Write-RgFileAtomic $progPath (ConvertTo-Json -InputObject $o -Compress)
}
function Save-Json($Obj, [string]$Path) { Write-RgFileAtomic $Path (ConvertTo-Json -InputObject $Obj -Depth 8 -Compress) }

try {
    Write-Prog 'running' 0
    if ($Mode -eq 'candidates') {
        $items = @(Get-RgCandidates)
        $out = foreach ($i in $items) {
            [pscustomobject]@{
                key = (Get-RgSha256 ("{0}|{1}|{2}|{3}" -f $i.kind, $i.path, $i.pid, $i.start)).Substring(0, 12)
                kind = $i.kind; action = $i.action; level = $i.level; path = $i.path; pid = $i.pid; start = $i.start; name = $i.name
                sizeBytes = $i.sizeBytes; ageDays = $i.ageDays; newestWriteUtc = $i.newestWriteUtc; reason = $i.reason; risk = $i.risk; needsAdmin = [bool]$i.needsAdmin
            }
        }
        Save-Json ([ordered]@{ finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1); items = @($out) }) $outPath
        Write-Prog 'done' 100 $items.Count 0 '' "$($items.Count) ứng viên"
        return
    }

    # ---------- breakdown ----------
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;

public class RgAgg { public long Bytes; public long Files; public long NewestTicks; }
public class RgRule { public string Prefix; public string Cat; public int KeyDepth; public bool Repo; }
public class RgWork { public string Dir; public RgRule Rule; public string Cat; public int Depth; }

public class RgDiskScanner
{
    public long FilesScanned, BytesScanned, Errors;
    public volatile string Current = "";
    public volatile bool Cancel;
    public Dictionary<string, RgAgg> Result = new Dictionary<string, RgAgg>();
    Dictionary<string, RgRule> ruleByDir = new Dictionary<string, RgRule>(StringComparer.OrdinalIgnoreCase);
    ConcurrentQueue<RgWork> queue = new ConcurrentQueue<RgWork>();
    int pending; int alive; int splitDepth = 3;
    object mergeLock = new object();
    const FileAttributes Skip = (FileAttributes)(0x1000 | 0x40000 | 0x400000); // offline / recall (file chỉ có trên cloud)

    public bool IsDone { get { return Interlocked.CompareExchange(ref alive, 0, 0) == 0; } }

    static string Long(string p) { return p.StartsWith(@"\\") ? p : @"\\?\" + p; }
    static string Strip(string p) { return p.StartsWith(@"\\?\") ? p.Substring(4) : p; }

    public void Start(string root, RgRule[] rules, int threads)
    {
        RgRule def = new RgRule { Prefix = root.TrimEnd('\\'), Cat = "other", KeyDepth = 1 };
        ruleByDir[def.Prefix] = def;
        foreach (RgRule r in rules) ruleByDir[r.Prefix.TrimEnd('\\')] = r;
        pending = 1;
        queue.Enqueue(new RgWork { Dir = root, Rule = def, Cat = def.Cat, Depth = 0 });
        alive = threads;
        for (int i = 0; i < threads; i++)
        {
            Thread t = new Thread(Worker); t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }
    }

    void Worker()
    {
        Dictionary<string, RgAgg> local = new Dictionary<string, RgAgg>();
        try
        {
            while (!Cancel)
            {
                RgWork w;
                if (queue.TryDequeue(out w)) { try { RunWork(w, local); } catch { Interlocked.Increment(ref Errors); } Interlocked.Decrement(ref pending); }
                else if (Interlocked.CompareExchange(ref pending, 0, 0) == 0) break;
                else Thread.Sleep(5);
            }
        }
        finally
        {
            lock (mergeLock)
            {
                foreach (KeyValuePair<string, RgAgg> kv in local)
                {
                    RgAgg g; if (!Result.TryGetValue(kv.Key, out g)) { Result[kv.Key] = kv.Value; }
                    else { g.Bytes += kv.Value.Bytes; g.Files += kv.Value.Files; if (kv.Value.NewestTicks > g.NewestTicks) g.NewestTicks = kv.Value.NewestTicks; }
                }
            }
            Interlocked.Decrement(ref alive);
        }
    }

    static string KeyOf(RgRule r, string path)
    {
        if (r.KeyDepth <= 0 || path.Length <= r.Prefix.Length) return r.Prefix;
        string rel = path.Substring(r.Prefix.Length).TrimStart('\\');
        string[] parts = rel.Split('\\');
        int n = Math.Min(r.KeyDepth, parts.Length);
        return r.Prefix + "\\" + string.Join("\\", parts, 0, n);
    }

    void Add(Dictionary<string, RgAgg> agg, string cat, string key, long bytes, long ticks)
    {
        string k = cat + "\t" + key; RgAgg g;
        if (!agg.TryGetValue(k, out g)) { g = new RgAgg(); agg[k] = g; }
        g.Bytes += bytes; g.Files++; if (ticks > g.NewestTicks) g.NewestTicks = ticks;
    }

    void RunWork(RgWork w0, Dictionary<string, RgAgg> agg)
    {
        Stack<RgWork> st = new Stack<RgWork>(); st.Push(w0);
        while (st.Count > 0 && !Cancel)
        {
            RgWork w = st.Pop(); Current = w.Dir;
            List<FileSystemInfo> entries = new List<FileSystemInfo>();
            try { foreach (FileSystemInfo e in new DirectoryInfo(Long(w.Dir)).EnumerateFileSystemInfos()) entries.Add(e); }
            catch { Interlocked.Increment(ref Errors); }
            bool hasProj = false;
            if (w.Rule.Repo)
                foreach (FileSystemInfo e in entries)
                {
                    string n = e.Name;
                    if (n.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".fsproj", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".vbproj", StringComparison.OrdinalIgnoreCase)) { hasProj = true; break; }
                }
            foreach (FileSystemInfo e in entries)
            {
                FileAttributes a; try { a = e.Attributes; } catch { continue; }
                string full = Strip(e.FullName);
                if ((a & FileAttributes.Directory) != 0)
                {
                    if ((a & FileAttributes.ReparsePoint) != 0) continue;
                    RgRule r = w.Rule; string cat = w.Cat; RgRule ex;
                    if (ruleByDir.TryGetValue(full, out ex)) { r = ex; cat = ex.Cat; }
                    else if (r.Repo && cat == r.Cat)
                    {
                        string n = e.Name;
                        if (n.Equals("node_modules", StringComparison.OrdinalIgnoreCase)) cat = "node-modules";
                        else if (n.Equals(".git", StringComparison.OrdinalIgnoreCase)) cat = "git-data";
                        else if ((n.Equals("bin", StringComparison.OrdinalIgnoreCase) || n.Equals("obj", StringComparison.OrdinalIgnoreCase)) && hasProj) cat = "build-output";
                        else if (n.Equals(".angular", StringComparison.OrdinalIgnoreCase) || n.Equals("dist", StringComparison.OrdinalIgnoreCase)) cat = "build-output";
                    }
                    RgWork cw = new RgWork { Dir = full, Rule = r, Cat = cat, Depth = w.Depth + 1 };
                    if (w.Depth < splitDepth) { Interlocked.Increment(ref pending); queue.Enqueue(cw); } else st.Push(cw);
                }
                else
                {
                    if ((a & Skip) != 0) continue;
                    long len; long ticks;
                    try { len = ((FileInfo)e).Length; ticks = e.LastWriteTimeUtc.Ticks; } catch { Interlocked.Increment(ref Errors); continue; }
                    string cat = w.Cat; string key = KeyOf(w.Rule, full);
                    string ext = Path.GetExtension(full).ToLowerInvariant();
                    if (ext == ".vhdx" || ext == ".vmdk" || ext == ".vdi" || ext == ".avhdx") { cat = "vm-disks"; key = full; }
                    else if (w.Depth == 0 && (e.Name.Equals("pagefile.sys", StringComparison.OrdinalIgnoreCase) || e.Name.Equals("hiberfil.sys", StringComparison.OrdinalIgnoreCase) || e.Name.Equals("swapfile.sys", StringComparison.OrdinalIgnoreCase))) { cat = "system-files"; key = full; }
                    Add(agg, cat, key, len, ticks);
                    Interlocked.Increment(ref FilesScanned); Interlocked.Add(ref BytesScanned, len);
                }
            }
        }
    }
}
'@

    $root = "${Drive}:\"
    $profile_ = $env:USERPROFILE
    $cfg = Get-RgConfig
    $rules = New-Object System.Collections.ArrayList
    function Add-Rule([string]$Prefix, [string]$Cat, [int]$Depth, [bool]$Repo = $false) {
        if (-not $Prefix -or -not $Prefix.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
        $r = New-Object RgRule; $r.Prefix = $Prefix.TrimEnd('\'); $r.Cat = $Cat; $r.KeyDepth = $Depth; $r.Repo = $Repo
        [void]$rules.Add($r)
    }
    Add-Rule "${root}Windows" 'system-windows' 1
    Add-Rule "${root}Program Files" 'programs' 1
    Add-Rule "${root}Program Files (x86)" 'programs' 1
    Add-Rule "${root}ProgramData" 'program-data' 1
    Add-Rule "${root}`$Recycle.Bin" 'recycle-bin' 0
    Add-Rule "${root}Users" 'user-other' 2
    Add-Rule $profile_ 'user-other' 1
    foreach ($d in 'Documents', 'Desktop', 'Pictures', 'Videos', 'Music') { Add-Rule (Join-Path $profile_ $d) 'documents' 1 }
    Add-Rule (Join-Path $profile_ 'Downloads') 'downloads' 1
    Add-Rule (Join-Path $profile_ 'AppData') 'app-data' 2
    Add-Rule (Join-Path $profile_ 'AppData\Local\Temp') 'temp' 1
    foreach ($d in '.nuget', '.npm', '.dotnet', '.gradle', '.m2', '.cache') { Add-Rule (Join-Path $profile_ $d) 'dev-cache' 1 }
    foreach ($p in $cfg.cleanup.cacheDirs.PSObject.Properties) { Add-Rule (Expand-RgPath ([string]$p.Value)) 'dev-cache' 0 }
    foreach ($w in @($cfg.cleanup.workspaceRoots)) { Add-Rule (Expand-RgPath ([string]$w)) 'repos' 1 $true }

    $sc = New-Object RgDiskScanner
    $di = New-Object IO.DriveInfo($Drive)
    $total = [long]$di.TotalSize; $free = [long]$di.AvailableFreeSpace; $used = $total - $free
    $sc.Start($root, [RgRule[]]$rules.ToArray(), [math]::Max(1, $Threads))
    while (-not $sc.IsDone) {
        $pct = if ($used -gt 0) { [math]::Min(99, 100.0 * $sc.BytesScanned / $used) } else { 0 }
        Write-Prog 'running' $pct $sc.FilesScanned $sc.BytesScanned $sc.Current
        Start-Sleep -Milliseconds 700
    }

    $groups = @{}
    foreach ($kv in $sc.Result.GetEnumerator()) {
        $parts = $kv.Key.Split("`t", 2)
        if (-not $groups.ContainsKey($parts[0])) { $groups[$parts[0]] = New-Object System.Collections.ArrayList }
        [void]$groups[$parts[0]].Add([pscustomobject]@{ key = $parts[1]; bytes = [long]$kv.Value.Bytes; files = [long]$kv.Value.Files
                newestUtc = $(if ($kv.Value.NewestTicks -gt 0) { ([datetime]::new($kv.Value.NewestTicks, 'Utc')).ToString('o') } else { $null }) })
    }
    $cats = foreach ($g in $groups.GetEnumerator()) {
        $sorted = @($g.Value | Sort-Object bytes -Descending)
        $sum = 0L; $files = 0L; foreach ($s in $sorted) { $sum += $s.bytes; $files += $s.files }
        $top = @($sorted | Select-Object -First 40); $topSum = 0L; foreach ($s in $top) { $topSum += $s.bytes }
        [pscustomobject]@{ cat = $g.Key; bytes = $sum; files = $files; itemCount = $sorted.Count; items = $top; restBytes = ($sum - $topSum) }
    }
    $cats = @($cats | Sort-Object bytes -Descending)
    $scanned = [long]$sc.BytesScanned
    $result = [ordered]@{
        drive = $Drive; totalBytes = $total; freeBytes = $free; usedBytes = $used; scannedBytes = $scanned
        unscannedBytes = [math]::Max([long]0, [long]($used - $scanned)); errors = [long]$sc.Errors; files = [long]$sc.FilesScanned
        finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        categories = $cats
    }
    Save-Json $result $outPath
    Write-Prog 'done' 100 $sc.FilesScanned $scanned '' ("{0:n0} file, {1:n1} GB" -f $sc.FilesScanned, ($scanned / 1GB))
}
catch {
    Write-RgLog 'scan-error' ([ordered]@{ mode = $Mode; error = [string]$_ })
    Write-Prog 'error' 0 0 0 '' ([string]$_.Exception.Message)
    exit 1
}
