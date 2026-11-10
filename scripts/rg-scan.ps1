# rg-scan.ps1 - quét nền, chạy ở process riêng (server không bị chặn). Chỉ ĐỌC, không xoá gì.
#   -Mode breakdown  : phân tích MỘT ổ đĩa (-Drive D) theo nhóm nhân tố (C# đa luồng, liệt kê bằng FindFirstFileExW) -> state\scan-breakdown-<ổ>.json
#                      + cây thư mục state\scan-tree-<ổ>.json + phần vùng cố định state\scan-fixed-<ổ>.json
#   -Mode candidates : danh sách ứng viên dọn dẹp (Get-RgCandidates)   -> state\scan-candidates.json
# -Scope focus|full (chỉ breakdown, mặc định focus): trên ổ hệ thống, vùng 'fixed' (Windows, Program Files, ProgramData, hồ sơ người dùng khác)
#   không dọn được và ít đổi; 'focus' bỏ qua vùng đó và lấy số từ lượt quét đầy đủ gần nhất (nhóm gắn carried=true + scannedUtc cũ). 'full' quét hết.
#   Ổ không phải ổ hệ thống: mọi thứ là 'hot', focus = full.
# -Threads 0 = tự chọn min(8, số nhân logic).
# Tham số CHỈ dùng cho test: -RootOverride <thư mục> (quét một thư mục như thể là gốc ổ hệ thống; hồ sơ người dùng = <thư mục>\Users\me)
#   và -OutDir <thư mục> (nơi ghi/đọc kết quả + tiến độ thay cho state\).
# Tiến độ: scan-<mode>.progress.json (đọc bởi server/UI); breakdown có thêm cats = ảnh chụp tạm byte theo nhóm (cập nhật ~1 giây).
[CmdletBinding()]
param([ValidateSet('breakdown', 'candidates')][string]$Mode = 'breakdown', [string]$Drive = 'C', [int]$Threads = 0,
    [ValidateSet('focus', 'full')][string]$Scope = 'focus', [string]$RootOverride = '', [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')
$stateDir = Join-Path (Initialize-RgHome) 'state'
if ($OutDir) { [void](New-Item -ItemType Directory -Force -Path $OutDir); $stateDir = $OutDir }
$progPath = Join-Path $stateDir "scan-$Mode.progress.json"
$Drive = ([string]$Drive).TrimEnd(':', '\').ToUpperInvariant()
$outPath = Join-Path $stateDir "scan-$Mode.json"
if ($Mode -eq 'breakdown') {
    if ($Drive -notmatch '^[A-Z]$') { throw "Tên ổ không hợp lệ: '$Drive'" }
    $outPath = Join-Path $stateDir "scan-breakdown-$Drive.json"   # mỗi ổ một file kết quả; tiến độ dùng chung một file (mỗi lúc quét một ổ)
}
$started = Get-Date

function Write-Prog([string]$Status, [double]$Pct, [long]$Files = 0, [long]$Bytes = 0, [string]$Cur = '', [string]$Msg = '', $Cats = $null) {
    $o = [ordered]@{ mode = $Mode; drive = $(if ($Mode -eq 'breakdown') { $Drive } else { $null }); scope = $(if ($Mode -eq 'breakdown') { $Scope } else { $null }); pid = $PID; status = $Status; pct = [math]::Round($Pct, 1); files = $Files; bytes = $Bytes; current = $Cur; message = $Msg
        startedUtc = $started.ToUniversalTime().ToString('o'); updatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    if ($null -ne $Cats) { $o['cats'] = @($Cats) }
    Write-RgFileAtomic $progPath (ConvertTo-Json -InputObject $o -Compress -Depth 4)
}
# PS 7 Ä‘á»•i chuá»—i ISO khi Ä‘á»c JSON thÃ nh DateTime; luÃ´n Ä‘Æ°a vá» chuá»—i ISO 'o' (UTC) Ä‘á»ƒ so sÃ¡nh/ghi láº¡i giá»‘ng nhau trÃªn cáº£ 5.1 vÃ  7+.
function ToIso($V) { if ($null -eq $V) { return $null }; if ($V -is [datetime]) { return $V.ToUniversalTime().ToString('o') }; return [string]$V }
function Save-Json($Obj, [string]$Path) { Write-RgFileAtomic $Path (ConvertTo-Json -InputObject $Obj -Depth 8 -Compress) }

try {
    Write-Prog 'running' 0
    if ($Mode -eq 'candidates') {
        $items = @(Get-RgCandidates)
        $out = foreach ($i in $items) {
            [pscustomobject]@{
                key = (Get-RgSha256 (("{0}|{1}|{2}|{3}" -f $i.kind, $i.path, $i.pid, $i.start) + $(if ([bool]$i.young) { '|young' } else { '' }))).Substring(0, 12)
                kind = $i.kind; action = $i.action; level = $i.level; path = $i.path; drive = (Get-RgPathDrive ([string]$i.path)); pid = $i.pid; start = $i.start; name = $i.name
                sizeBytes = $i.sizeBytes; ageDays = $i.ageDays; newestWriteUtc = $i.newestWriteUtc; reason = $i.reason; risk = $i.risk; needsAdmin = [bool]$i.needsAdmin; young = [bool]$i.young
                why = [string]$i.why; impact = [string]$i.impact; regen = [string]$i.regen; regenHint = [string]$i.regenHint; riskLevel = [string]$i.riskLevel
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
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class RgAgg { public long Bytes; public long Files; public long NewestTicks; }
public class RgTreeAgg { public long Bytes; public long Files; public long NewestTicks; public string Cat; public string Zone; }
public class RgRule { public string Prefix; public string Cat; public int KeyDepth; public bool Repo; public string Zone; }
public class RgWork { public string Dir; public RgRule Rule; public string Cat; public int Depth; public int RelDepth; public string TreeKey; public string TreeCat; public string TreeZone; }
public class RgLocal { public Dictionary<string, RgAgg> Agg = new Dictionary<string, RgAgg>(); public Dictionary<string, RgTreeAgg> Tree = new Dictionary<string, RgTreeAgg>(); public Dictionary<string, long[]> Cat = new Dictionary<string, long[]>(); public int Pend; }
public class RgTreeNode { public string Key; public string Cat; public string Zone; public long Own; public long Bytes; public long Files; public long Newest; public List<RgTreeNode> Kids = new List<RgTreeNode>(); }

// Liệt kê một thư mục bằng FindFirstFileExW (FindExInfoBasic + FIND_FIRST_EX_LARGE_FETCH): kích thước và thời gian lấy ngay trong bản ghi tìm kiếm.
public static class RgWin32
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FindData
    {
        public uint Attr; public uint CLo; public uint CHi; public uint ALo; public uint AHi; public uint WLo; public uint WHi;
        public uint SizeHi; public uint SizeLo; public uint Res0; public uint Res1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string Alt;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "FindFirstFileExW")]
    static extern IntPtr FindFirstFileEx(string name, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindNextFileW")]
    static extern bool FindNext(IntPtr h, out FindData data);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr h);

    public struct Entry { public string Name; public uint Attr; public long Size; public long WriteTicks; }
    const long FileTimeToTicks = 504911232000000000L;

    public static string Long(string p) { return p.StartsWith(@"\\") ? p : @"\\?\" + p; }

    // null nếu không mở được (từ chối truy cập, biến mất...); err = mã lỗi Win32.
    public static List<Entry> List(string dir, out int err)
    {
        err = 0;
        string pat = Long(dir) + (dir.EndsWith("\\") ? "*" : "\\*");
        FindData d;
        IntPtr h = FindFirstFileEx(pat, 1, out d, 0, IntPtr.Zero, 2);
        if (h == (IntPtr)(-1)) { err = Marshal.GetLastWin32Error(); return null; }
        List<Entry> res = new List<Entry>();
        try
        {
            do
            {
                string n = d.Name;
                if (n == "." || n == "..") continue;
                Entry e = new Entry();
                e.Name = n; e.Attr = d.Attr;
                e.Size = ((long)d.SizeHi << 32) | (long)d.SizeLo;
                e.WriteTicks = (((long)d.WHi << 32) | (long)d.WLo) + FileTimeToTicks;
                res.Add(e);
            } while (FindNext(h, out d));
        }
        finally { FindClose(h); }
        return res;
    }
}

public class RgDiskScanner
{
    public long FilesScanned, BytesScanned, Errors, SkippedDirs;
    public volatile string Current = "";
    public volatile bool Cancel;
    public Dictionary<string, RgAgg> Result = new Dictionary<string, RgAgg>();
    public Dictionary<string, RgTreeAgg> Tree = new Dictionary<string, RgTreeAgg>();
    public int TreeDepth = 5;
    public bool SkipFixed;
    Dictionary<string, long> catLive = new Dictionary<string, long>();
    Dictionary<string, RgRule> ruleByDir = new Dictionary<string, RgRule>(StringComparer.OrdinalIgnoreCase);
    ConcurrentQueue<RgWork> queue = new ConcurrentQueue<RgWork>();
    int pending; int alive; int splitDepth = 3;
    object mergeLock = new object();
    const uint Skip = 0x1000 | 0x40000 | 0x400000; // offline / recall (file chỉ có trên cloud)

    public bool IsDone { get { return Interlocked.CompareExchange(ref alive, 0, 0) == 0; } }

    static string Join(string dir, string name) { return dir.EndsWith("\\") ? dir + name : dir + "\\" + name; }

    public void Start(string root, RgRule[] rules, int threads, string defZone)
    {
        RgRule def = new RgRule { Prefix = root.TrimEnd('\\'), Cat = "other", KeyDepth = 1, Zone = defZone };
        ruleByDir[def.Prefix] = def;
        foreach (RgRule r in rules) ruleByDir[r.Prefix.TrimEnd('\\')] = r;
        pending = 1;
        queue.Enqueue(new RgWork { Dir = root, Rule = def, Cat = def.Cat, Depth = 0, RelDepth = 0, TreeKey = root.TrimEnd('\\'), TreeCat = def.Cat, TreeZone = def.Zone });
        alive = threads;
        for (int i = 0; i < threads; i++)
        {
            Thread t = new Thread(Worker); t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }
    }

    // Ảnh chụp tạm byte theo nhóm: "cat\tbytes".
    public string[] SnapshotCats()
    {
        lock (mergeLock)
        {
            List<string> l = new List<string>();
            foreach (KeyValuePair<string, long> kv in catLive) l.Add(kv.Key + "\t" + kv.Value.ToString(CultureInfo.InvariantCulture));
            return l.ToArray();
        }
    }

    void FlushCats(RgLocal loc)
    {
        lock (mergeLock)
        {
            foreach (KeyValuePair<string, long[]> kv in loc.Cat)
            {
                if (kv.Value[0] == 0) continue;
                long cur; catLive.TryGetValue(kv.Key, out cur); catLive[kv.Key] = cur + kv.Value[0];
                kv.Value[0] = 0;
            }
        }
        loc.Pend = 0;
    }

    void Worker()
    {
        RgLocal loc = new RgLocal();
        try
        {
            while (!Cancel)
            {
                RgWork w;
                if (queue.TryDequeue(out w)) { try { RunWork(w, loc); } catch { Interlocked.Increment(ref Errors); } Interlocked.Decrement(ref pending); }
                else if (Interlocked.CompareExchange(ref pending, 0, 0) == 0) break;
                else Thread.Sleep(5);
            }
        }
        finally
        {
            FlushCats(loc);
            lock (mergeLock)
            {
                foreach (KeyValuePair<string, RgAgg> kv in loc.Agg)
                {
                    RgAgg g; if (!Result.TryGetValue(kv.Key, out g)) { Result[kv.Key] = kv.Value; }
                    else { g.Bytes += kv.Value.Bytes; g.Files += kv.Value.Files; if (kv.Value.NewestTicks > g.NewestTicks) g.NewestTicks = kv.Value.NewestTicks; }
                }
                foreach (KeyValuePair<string, RgTreeAgg> kv in loc.Tree)
                {
                    RgTreeAgg g; if (!Tree.TryGetValue(kv.Key, out g)) { Tree[kv.Key] = kv.Value; }
                    else
                    {
                        g.Bytes += kv.Value.Bytes; g.Files += kv.Value.Files; if (kv.Value.NewestTicks > g.NewestTicks) g.NewestTicks = kv.Value.NewestTicks;
                        if (kv.Value.Cat != null && kv.Key.Length > 0) { g.Cat = kv.Value.Cat; g.Zone = kv.Value.Zone; }
                    }
                }
            }
            Interlocked.Decrement(ref alive);
        }
    }

    // Số phần của đường dẫn tương đối dưới tiền tố rule và khoá cố định cho cả thư mục (null nếu khoá phải gồm tên file).
    static string DirKey(RgRule r, string dir, out bool perFile)
    {
        perFile = false;
        if (r.KeyDepth <= 0) return r.Prefix;
        string rel = dir.Length <= r.Prefix.Length ? "" : dir.Substring(r.Prefix.Length).TrimStart('\\');
        int parts = rel.Length == 0 ? 0 : rel.Split('\\').Length;
        if (parts < r.KeyDepth) { perFile = true; return null; }
        string[] p = rel.Split('\\');
        return r.Prefix + "\\" + string.Join("\\", p, 0, r.KeyDepth);
    }

    RgTreeAgg Node(Dictionary<string, RgTreeAgg> t, string key, string cat, string zone)
    {
        RgTreeAgg n;
        if (!t.TryGetValue(key, out n)) { n = new RgTreeAgg(); n.Cat = cat; n.Zone = zone; t[key] = n; }
        return n;
    }

    void RunWork(RgWork w0, RgLocal loc)
    {
        Stack<RgWork> st = new Stack<RgWork>(); st.Push(w0);
        while (st.Count > 0 && !Cancel)
        {
            RgWork w = st.Pop(); Current = w.Dir;
            int err; List<RgWin32.Entry> entries = RgWin32.List(w.Dir, out err);
            if (entries == null) { Interlocked.Increment(ref Errors); entries = new List<RgWin32.Entry>(); }
            RgTreeAgg node = Node(loc.Tree, w.TreeKey, w.TreeCat, w.TreeZone);
            bool hasProj = false;
            if (w.Rule.Repo)
                foreach (RgWin32.Entry e in entries)
                {
                    string n = e.Name;
                    if (n.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".fsproj", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".vbproj", StringComparison.OrdinalIgnoreCase)) { hasProj = true; break; }
                }
            bool perFile; string dirKey = DirKey(w.Rule, w.Dir, out perFile);
            string lastCat = null, lastKey = null; RgAgg lastAgg = null; long[] lastCatArr = null; string lastCatName = null;
            foreach (RgWin32.Entry e in entries)
            {
                uint a = e.Attr;
                if ((a & 0x10) != 0)
                {
                    if ((a & 0x400) != 0) continue;
                    string full = Join(w.Dir, e.Name);
                    RgRule r = w.Rule; string cat = w.Cat; RgRule ex; bool isRule = false;
                    if (ruleByDir.TryGetValue(full, out ex)) { r = ex; cat = ex.Cat; isRule = true; }
                    else if (r.Repo && cat == r.Cat)
                    {
                        string n = e.Name;
                        if (n.Equals("node_modules", StringComparison.OrdinalIgnoreCase)) cat = "node-modules";
                        else if (n.Equals(".git", StringComparison.OrdinalIgnoreCase)) cat = "git-data";
                        else if ((n.Equals("bin", StringComparison.OrdinalIgnoreCase) || n.Equals("obj", StringComparison.OrdinalIgnoreCase)) && hasProj) cat = "build-output";
                        else if (n.Equals(".angular", StringComparison.OrdinalIgnoreCase) || n.Equals("dist", StringComparison.OrdinalIgnoreCase)) cat = "build-output";
                    }
                    if (SkipFixed && r.Zone == "fixed") { Interlocked.Increment(ref SkippedDirs); continue; }
                    RgWork cw = new RgWork { Dir = full, Rule = r, Cat = cat, Depth = w.Depth + 1, RelDepth = isRule ? 0 : w.RelDepth + 1 };
                    if (cw.RelDepth <= TreeDepth) { cw.TreeKey = full; cw.TreeCat = cat; cw.TreeZone = r.Zone; }
                    else { cw.TreeKey = w.TreeKey; cw.TreeCat = w.TreeCat; cw.TreeZone = w.TreeZone; }
                    if (w.Depth < splitDepth) { Interlocked.Increment(ref pending); queue.Enqueue(cw); } else st.Push(cw);
                }
                else
                {
                    if ((a & Skip) != 0) continue;
                    long len = e.Size; long ticks = e.WriteTicks;
                    string cat = w.Cat; string key;
                    string ext = Path.GetExtension(e.Name);
                    if (ext.Length >= 4 && (ext.Equals(".vhdx", StringComparison.OrdinalIgnoreCase) || ext.Equals(".vmdk", StringComparison.OrdinalIgnoreCase) || ext.Equals(".vdi", StringComparison.OrdinalIgnoreCase) || ext.Equals(".avhdx", StringComparison.OrdinalIgnoreCase))) { cat = "vm-disks"; key = Join(w.Dir, e.Name); }
                    else if (w.Depth == 0 && (e.Name.Equals("pagefile.sys", StringComparison.OrdinalIgnoreCase) || e.Name.Equals("hiberfil.sys", StringComparison.OrdinalIgnoreCase) || e.Name.Equals("swapfile.sys", StringComparison.OrdinalIgnoreCase))) { cat = "system-files"; key = Join(w.Dir, e.Name); }
                    else key = perFile ? Join(w.Dir, e.Name) : dirKey;
                    RgAgg g;
                    if (lastAgg != null && (object)cat == (object)lastCat && key == lastKey) g = lastAgg;
                    else
                    {
                        string k = cat + "\t" + key;
                        if (!loc.Agg.TryGetValue(k, out g)) { g = new RgAgg(); loc.Agg[k] = g; }
                        lastAgg = g; lastCat = cat; lastKey = key;
                    }
                    g.Bytes += len; g.Files++; if (ticks > g.NewestTicks) g.NewestTicks = ticks;
                    node.Bytes += len; node.Files++; if (ticks > node.NewestTicks) node.NewestTicks = ticks;
                    if (lastCatArr == null || (object)cat != (object)lastCatName)
                    {
                        if (!loc.Cat.TryGetValue(cat, out lastCatArr)) { lastCatArr = new long[1]; loc.Cat[cat] = lastCatArr; }
                        lastCatName = cat;
                    }
                    lastCatArr[0] += len;
                    Interlocked.Increment(ref FilesScanned); Interlocked.Add(ref BytesScanned, len);
                    if (++loc.Pend >= 4096) FlushCats(loc);
                }
            }
        }
    }

    // ---- cây thư mục: cộng dồn từ nút con lên cha, gộp nút nhỏ (< minBytes) vào "(khác)" ----
    static string Iso(long ticks) { return ticks <= 504911232000000000L ? "null" : "\"" + new DateTime(ticks, DateTimeKind.Utc).ToString("o") + "\""; }
    static void Esc(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            if (c == '"') sb.Append("\\\""); else if (c == '\\') sb.Append("\\\\");
            else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c);
        }
        sb.Append('"');
    }
    static string Num(long v) { return v.ToString(CultureInfo.InvariantCulture); }

    public string BuildTreeJson(string rootKey, string rootPath, long minBytes)
    {
        Dictionary<string, RgTreeNode> nodes = new Dictionary<string, RgTreeNode>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, RgTreeAgg> kv in Tree)
        {
            RgTreeNode n = new RgTreeNode(); n.Key = kv.Key; n.Cat = kv.Value.Cat; n.Zone = kv.Value.Zone;
            n.Own = kv.Value.Bytes; n.Bytes = kv.Value.Bytes; n.Files = kv.Value.Files; n.Newest = kv.Value.NewestTicks;
            nodes[kv.Key] = n;
        }
        RgTreeNode root;
        if (!nodes.TryGetValue(rootKey, out root)) { root = new RgTreeNode(); root.Key = rootKey; root.Cat = "other"; root.Zone = "warm"; nodes[rootKey] = root; }
        List<RgTreeNode> list = new List<RgTreeNode>(nodes.Values);
        list.Sort(delegate(RgTreeNode a, RgTreeNode b) { return b.Key.Length.CompareTo(a.Key.Length); });
        foreach (RgTreeNode n in list)
        {
            if (n == root) continue;
            RgTreeNode p = root; string s = n.Key;
            while (true)
            {
                int i = s.LastIndexOf('\\');
                if (i <= 0) break;
                s = s.Substring(0, i);
                RgTreeNode q; if (nodes.TryGetValue(s, out q)) { p = q; break; }
            }
            p.Kids.Add(n); p.Bytes += n.Bytes; p.Files += n.Files; if (n.Newest > p.Newest) p.Newest = n.Newest;
        }
        StringBuilder sb = new StringBuilder();
        Emit(sb, root, rootPath, rootPath, null, minBytes);
        return sb.ToString();
    }

    static void Emit(StringBuilder sb, RgTreeNode n, string name, string path, string parentKey, long minBytes)
    {
        sb.Append("{\"name\":"); Esc(sb, name); sb.Append(",\"path\":"); Esc(sb, path);
        sb.Append(",\"bytes\":").Append(Num(n.Bytes)).Append(",\"files\":").Append(Num(n.Files)).Append(",\"own\":").Append(Num(n.Own));
        sb.Append(",\"newestUtc\":").Append(Iso(n.Newest)).Append(",\"cat\":"); Esc(sb, n.Cat ?? "other"); sb.Append(",\"zone\":"); Esc(sb, n.Zone ?? "warm");
        sb.Append(",\"children\":[");
        n.Kids.Sort(delegate(RgTreeNode a, RgTreeNode b) { return b.Bytes.CompareTo(a.Bytes); });
        bool first = true; long restB = 0, restF = 0, restN = 0; int restCount = 0;
        foreach (RgTreeNode k in n.Kids)
        {
            if (k.Bytes < minBytes) { restB += k.Bytes; restF += k.Files; if (k.Newest > restN) restN = k.Newest; restCount++; continue; }
            if (!first) sb.Append(','); first = false;
            string kn = k.Key.Length > n.Key.Length && k.Key.StartsWith(n.Key, StringComparison.OrdinalIgnoreCase) ? k.Key.Substring(n.Key.Length).TrimStart('\\') : k.Key;
            Emit(sb, k, kn, k.Key, n.Key, minBytes);
        }
        if (restCount > 0)
        {
            if (!first) sb.Append(',');
            sb.Append("{\"name\":\"(khác)\",\"path\":"); Esc(sb, path);
            sb.Append(",\"bytes\":").Append(Num(restB)).Append(",\"files\":").Append(Num(restF)).Append(",\"own\":").Append(Num(restB));
            sb.Append(",\"newestUtc\":").Append(Iso(restN)).Append(",\"cat\":"); Esc(sb, n.Cat ?? "other"); sb.Append(",\"zone\":"); Esc(sb, n.Zone ?? "warm");
            sb.Append(",\"rest\":true,\"count\":").Append(Num(restCount)).Append(",\"children\":[]}");
        }
        sb.Append("]}");
    }
}
'@

    $isOverride = [bool]$RootOverride
    $sysLetter = ([string]$env:SystemDrive).TrimEnd(':', '\').ToUpperInvariant()
    if ($isOverride) {
        if (-not (Test-Path -LiteralPath $RootOverride -PathType Container)) { throw "RootOverride không phải thư mục: $RootOverride" }
        $root = ([IO.Path]::GetFullPath($RootOverride)).TrimEnd('\') + '\'
        $profile_ = Join-Path $root 'Users\me'
    }
    else {
        if (-not (@(Get-RgDrives) | Where-Object { $_.drive -eq $Drive })) { throw "Ổ $Drive`: không có, chưa sẵn sàng hoặc không phải ổ cố định." }
        $root = "${Drive}:\"
        $profile_ = $env:USERPROFILE
    }
    $isSys = $isOverride -or ($Drive -eq $sysLetter)
    $skipFixed = ($Scope -eq 'focus') -and $isSys
    $cfg = Get-RgConfig
    $rules = New-Object System.Collections.ArrayList
    $fixedPrefixes = New-Object System.Collections.ArrayList
    # Zone: fixed = không dọn được, ít đổi (bỏ qua ở 'focus'); hot = nơi dọn được; warm = còn lại. Ổ không phải ổ hệ thống: tất cả hot.
    function Add-Rule([string]$Prefix, [string]$Cat, [int]$Depth, [bool]$Repo = $false, [string]$Zone = 'warm') {
        if (-not $Prefix -or -not $Prefix.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
        $r = New-Object RgRule; $r.Prefix = $Prefix.TrimEnd('\'); $r.Cat = $Cat; $r.KeyDepth = $Depth; $r.Repo = $Repo
        $r.Zone = $(if ($isSys) { $Zone } else { 'hot' })
        if ($r.Zone -eq 'fixed') { [void]$fixedPrefixes.Add($r.Prefix) }
        [void]$rules.Add($r)
    }
    Add-Rule "${root}Windows" 'system-windows' 1 $false 'fixed'
    Add-Rule "${root}Program Files" 'programs' 1 $false 'fixed'
    Add-Rule "${root}Program Files (x86)" 'programs' 1 $false 'fixed'
    Add-Rule "${root}ProgramData" 'program-data' 1 $false 'fixed'
    Add-Rule "${root}`$Recycle.Bin" 'recycle-bin' 0 $false 'hot'
    Add-Rule "${root}Users" 'user-other' 2 $false 'warm'
    # Mỗi hồ sơ người dùng KHÁC là một rule cố định (khoá giống hệt khi Users có KeyDepth 2), hồ sơ của mình đi theo rule bên dưới.
    $usersDir = "${root}Users"
    if ($isSys -and (Test-Path -LiteralPath $usersDir -PathType Container)) {
        foreach ($ud in @(Get-ChildItem -LiteralPath $usersDir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($ud.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($ud.FullName.TrimEnd('\') -ieq $profile_.TrimEnd('\')) { continue }
            Add-Rule $ud.FullName 'user-other' 1 $false 'fixed'
        }
    }
    Add-Rule $profile_ 'user-other' 1 $false 'warm'
    foreach ($d in 'Documents', 'Desktop', 'Pictures', 'Videos', 'Music') { Add-Rule (Join-Path $profile_ $d) 'documents' 1 $false 'warm' }
    Add-Rule (Join-Path $profile_ 'Downloads') 'downloads' 1 $false 'hot'
    Add-Rule (Join-Path $profile_ 'AppData') 'app-data' 2 $false 'warm'
    Add-Rule (Join-Path $profile_ 'AppData\Local\Temp') 'temp' 1 $false 'hot'
    foreach ($d in '.nuget', '.npm', '.dotnet', '.gradle', '.m2', '.cache') { Add-Rule (Join-Path $profile_ $d) 'dev-cache' 1 $false 'hot' }
    foreach ($p in $cfg.cleanup.cacheDirs.PSObject.Properties) { Add-Rule (Expand-RgPath ([string]$p.Value)) 'dev-cache' 0 $false 'hot' }
    foreach ($w in @(Get-RgWorkspaceRoots $cfg.cleanup)) { Add-Rule ([string]$w) 'repos' 1 $true 'hot' }

    # Thuộc tính của từng nhóm cho UI: zone (cách quét) và actionable (fixed = không có gì để làm, review = xem rồi tự quyết, cleanable = dọn được).
    $catMeta = @{
        'system-windows' = @('fixed', 'fixed'); 'programs' = @('fixed', 'fixed'); 'program-data' = @('fixed', 'fixed'); 'system-files' = @('fixed', 'fixed')
        'recycle-bin' = @('hot', 'cleanable'); 'temp' = @('hot', 'cleanable'); 'dev-cache' = @('hot', 'cleanable'); 'node-modules' = @('hot', 'cleanable'); 'build-output' = @('hot', 'cleanable')
        'repos' = @('hot', 'review'); 'git-data' = @('hot', 'review'); 'downloads' = @('hot', 'review')
        'vm-disks' = @('warm', 'review'); 'app-data' = @('warm', 'review'); 'documents' = @('warm', 'review'); 'other' = @('warm', 'review'); 'user-other' = @('warm', 'fixed')
    }

    $fixedPath = Join-Path $stateDir "scan-fixed-$Drive.json"
    $treePath = Join-Path $stateDir "scan-tree-$Drive.json"
    function Test-FixedKey([string]$Key) {
        foreach ($p in $fixedPrefixes) { if ($Key.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or $Key.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }

    $sc = New-Object RgDiskScanner
    $sc.SkipFixed = $skipFixed
    if ($isOverride) { $total = 0L; $free = 0L; $used = 0L }
    else { $di = New-Object IO.DriveInfo($Drive); $total = [long]$di.TotalSize; $free = [long]$di.AvailableFreeSpace; $used = $total - $free }
    if ($Threads -le 0) { $Threads = [math]::Min(8, [Environment]::ProcessorCount) }
    $defZone = $(if ($isSys) { 'warm' } else { 'hot' })
    $sc.Start($root, [RgRule[]]$rules.ToArray(), [math]::Max(1, $Threads), $defZone)
    $lastProg = [datetime]::MinValue
    while (-not $sc.IsDone) {
        $pct = if ($used -gt 0) { [math]::Min(99, 100.0 * $sc.BytesScanned / $used) } else { 0 }
        $snap = @($sc.SnapshotCats() | ForEach-Object { $p = $_.Split("`t"); [pscustomobject]@{ cat = $p[0]; bytes = [long]$p[1] } } | Sort-Object bytes -Descending | Select-Object -First 16)
        Write-Prog 'running' $pct $sc.FilesScanned $sc.BytesScanned $sc.Current '' $snap
        Start-Sleep -Milliseconds 700
    }
    $finishedUtc = (Get-Date).ToUniversalTime().ToString('o')

    # --- gộp kết quả quét mới + (focus) phần vùng cố định lấy từ lượt quét đầy đủ gần nhất ---
    $rows = New-Object System.Collections.ArrayList
    foreach ($kv in $sc.Result.GetEnumerator()) {
        $parts = $kv.Key.Split("`t", 2)
        [void]$rows.Add([pscustomobject]@{ cat = $parts[0]; key = $parts[1]; bytes = [long]$kv.Value.Bytes; files = [long]$kv.Value.Files
                newestUtc = $(if ($kv.Value.NewestTicks -gt 0) { ([datetime]::new($kv.Value.NewestTicks, 'Utc')).ToString('o') } else { $null }); carried = $false; scannedUtc = $finishedUtc })
    }
    $carriedBytes = 0L; $carriedFound = $false
    if ($isSys) {
        if ($Scope -eq 'full') {
            # Lưu phần vùng cố định để các lượt focus sau mượn lại.
            $fx = @($rows | Where-Object { Test-FixedKey ([string]$_.key) } | ForEach-Object { [pscustomobject]@{ cat = $_.cat; key = $_.key; bytes = $_.bytes; files = $_.files; newestUtc = $_.newestUtc } })
            Save-Json ([ordered]@{ drive = $Drive; scannedUtc = $finishedUtc; entries = $fx }) $fixedPath
        }
        elseif (Test-Path -LiteralPath $fixedPath) {
            try {
                $old = ConvertFrom-Json (Get-Content -LiteralPath $fixedPath -Raw -Encoding UTF8)
                foreach ($e in @($old.entries)) {
                    [void]$rows.Add([pscustomobject]@{ cat = [string]$e.cat; key = [string]$e.key; bytes = [long]$e.bytes; files = [long]$e.files; newestUtc = (ToIso $e.newestUtc); carried = $true; scannedUtc = (ToIso $old.scannedUtc) })
                    $carriedBytes += [long]$e.bytes
                }
                $carriedFound = $true
            } catch { Write-RgLog 'scan-error' ([ordered]@{ mode = 'breakdown'; error = "scan-fixed không đọc được: $($_.Exception.Message)" }) }
        }
    }

    $groups = @{}
    foreach ($r in $rows) {
        if (-not $groups.ContainsKey($r.cat)) { $groups[$r.cat] = New-Object System.Collections.ArrayList }
        [void]$groups[$r.cat].Add($r)
    }
    $cats = foreach ($g in $groups.GetEnumerator()) {
        $sorted = @($g.Value | Sort-Object bytes -Descending)
        $sum = 0L; $files = 0L; $carried = 0L; $oldest = $finishedUtc
        foreach ($s in $sorted) { $sum += $s.bytes; $files += $s.files; if ($s.carried) { $carried += $s.bytes; if ([string]$s.scannedUtc -lt $oldest) { $oldest = [string]$s.scannedUtc } } }
        $top = @($sorted | Select-Object -First 40); $topSum = 0L; foreach ($s in $top) { $topSum += $s.bytes }
        $meta = $catMeta[[string]$g.Key]; if (-not $meta) { $meta = @('warm', 'review') }
        [pscustomobject]@{ cat = $g.Key; bytes = $sum; files = $files; itemCount = $sorted.Count
            items = @($top | ForEach-Object { [pscustomobject]@{ key = $_.key; bytes = $_.bytes; files = $_.files; newestUtc = $_.newestUtc } }); restBytes = ($sum - $topSum)
            zone = $(if ($isSys) { $meta[0] } else { 'hot' }); actionable = $meta[1]; scannedUtc = $oldest; carried = ($carried -gt 0); carriedBytes = $carried }
    }
    $cats = @($cats | Sort-Object bytes -Descending)
    $fresh = [long]$sc.BytesScanned
    $scanned = $fresh + $carriedBytes
    if ($isOverride) { $used = $scanned; $total = $scanned; $free = 0L }

    # --- cây thư mục ---
    $minNode = [long][math]::Max(100MB, [math]::Floor(0.002 * $used))
    if ($isOverride) { $minNode = 0L }
    $rootKey = $root.TrimEnd('\')
    $rootJson = $sc.BuildTreeJson($rootKey, $root, $minNode)
    if ($isSys -and $skipFixed) {
        $rt = ConvertFrom-Json $rootJson
        $grafted = 0L
        $oldTree = $null
        if (Test-Path -LiteralPath $treePath) { try { $oldTree = ConvertFrom-Json (Get-Content -LiteralPath $treePath -Raw -Encoding UTF8) } catch { } }
        function Find-TreeNode($N, [string]$P) {
            if ([string]$N.path -ieq $P -and -not $N.rest) { return $N }
            foreach ($c in @($N.children)) {
                if ($c.rest) { continue }
                $cp = [string]$c.path
                if ($P.StartsWith($cp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $cp -ieq $P) { $f = Find-TreeNode $c $P; if ($f) { return $f } }
            }
            return $null
        }
        function Add-TreeBytes($Chain, [long]$B, [long]$F, $Newest) {
            foreach ($n in $Chain) {
                $n.bytes = [long]$n.bytes + $B; $n.files = [long]$n.files + $F
                if ($Newest -and ((ToIso $Newest) -gt (ToIso $n.newestUtc))) { $n.newestUtc = (ToIso $Newest) }
            }
        }
        function Add-TreeChild($Rt, $Child) {
            # tìm nút cha gần nhất (nút có đường dẫn là tiền tố) và treo vào đó, cộng dồn lên cả chuỗi tổ tiên
            $chain = New-Object System.Collections.ArrayList; $cur = $Rt; [void]$chain.Add($cur)
            while ($true) {
                $next = $null
                foreach ($c in @($cur.children)) {
                    if ($c.rest) { continue }
                    $cp = ([string]$c.path).TrimEnd('\')
                    if ($Child.path.StartsWith($cp + '\', [StringComparison]::OrdinalIgnoreCase)) { $next = $c; break }
                }
                if (-not $next) { break }
                $cur = $next; [void]$chain.Add($cur)
            }
            $nm = [string]$Child.path
            $pp = ([string]$cur.path).TrimEnd('\')
            if ($nm.Length -gt $pp.Length + 1 -and $nm.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase)) { $Child.name = $nm.Substring($pp.Length).TrimStart('\') }
            $cur.children = @(@($cur.children) + @($Child) | Sort-Object { [long]$_.bytes } -Descending)
            Add-TreeChild-Sum $chain $Child
        }
        function Add-TreeChild-Sum($Chain, $Child) { Add-TreeBytes $Chain ([long]$Child.bytes) ([long]$Child.files) $Child.newestUtc }
        if ($oldTree -and $oldTree.root) {
            foreach ($fp in $fixedPrefixes) {
                if (Find-TreeNode $rt $fp) { continue }
                $on = Find-TreeNode $oldTree.root $fp
                if ($on) { Add-TreeChild $rt $on; $grafted += [long]$on.bytes }
            }
        }
        $gap = [long][math]::Max(0L, [long]($used - $fresh - $grafted))
        if ($gap -gt 0) {
            $syn = [pscustomobject]@{ name = 'Hệ thống & chương trình (chưa quét chi tiết)'; path = $root; bytes = $gap; files = 0; own = $gap; newestUtc = $null; cat = 'system-windows'; zone = 'fixed'; unscanned = $true; children = @() }
            $rt.children = @(@($rt.children) + @($syn) | Sort-Object { [long]$_.bytes } -Descending)
            $rt.bytes = [long]$rt.bytes + $gap
        }
        $rootJson = ConvertTo-Json -InputObject $rt -Depth 40 -Compress
    }
    $treeDoc = '{"drive":"' + $Drive + '","scope":"' + $Scope + '","usedBytes":' + [string][long]$used + ',"finishedUtc":"' + $finishedUtc + '","root":' + $rootJson + '}'
    Write-RgFileAtomic $treePath $treeDoc

    $result = [ordered]@{
        drive = $Drive; scope = $Scope; totalBytes = $total; freeBytes = $free; usedBytes = $used; scannedBytes = $scanned; freshBytes = $fresh; carriedBytes = $carriedBytes
        unscannedBytes = [math]::Max([long]0, [long]($used - $scanned)); errors = [long]$sc.Errors; files = [long]$sc.FilesScanned; skippedDirs = [long]$sc.SkippedDirs
        threads = $Threads; finishedUtc = $finishedUtc; seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        categories = $cats
    }
    Save-Json $result $outPath
    $doneCats = @($cats | Select-Object -First 16 | ForEach-Object { [pscustomobject]@{ cat = $_.cat; bytes = $_.bytes } })
    Write-Prog 'done' 100 $sc.FilesScanned $scanned '' ("{0:n0} file, {1:n1} GB" -f $sc.FilesScanned, ($scanned / 1GB)) $doneCats
}
catch {
    Write-RgLog 'scan-error' ([ordered]@{ mode = $Mode; error = [string]$_ })
    Write-Prog 'error' 0 0 0 '' ([string]$_.Exception.Message)
    exit 1
}
