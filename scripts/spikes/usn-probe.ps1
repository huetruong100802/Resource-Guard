# usn-probe.ps1 - SPIKE (P11): đọc USN journal của một ổ NTFS KHÔNG cần quyền admin được không, và bản ghi có gì dùng được.
# Chỉ ĐỌC: mở volume (\\.\X:), gọi FSCTL_QUERY_USN_JOURNAL rồi FSCTL_READ_UNPRIVILEGED_USN_JOURNAL (0x903AB), đọc tối đa 1000 bản ghi.
# Không ghi gì, không cần/đòi nâng quyền. Thất bại của FSCTL là KẾT QUẢ HỢP LỆ của spike: luôn thoát 0.
# Kết quả JSON: { osBuild, elevated, drive, handleAccess, queryOk, readOk, records, withName, sampleReasons, error, ... }
#   handleAccess : kiểu handle đã mở được ('none' = dwDesiredAccess 0, 'attr' = FILE_READ_ATTRIBUTES, 'read' = GENERIC_READ) hoặc null.
#   records      : số bản ghi đọc được;  withName: số bản ghi có tên file (FileNameLength > 0);  sampleReasons: tên cờ Reason của vài bản ghi đầu.
#   privilegedReadOk: thử thêm FSCTL_READ_USN_JOURNAL (0x900BB, cần admin) để so sánh.
[CmdletBinding()]
param([string]$Drive = 'C', [switch]$Json)
$ErrorActionPreference = 'Stop'
$Drive = ([string]$Drive).TrimEnd(':', '\').ToUpperInvariant()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class RgUsnProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr ov);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    public class Result
    {
        public string HandleAccess; public bool QueryOk; public bool ReadOk; public bool PrivReadOk;
        public int Records; public int WithName; public string Error; public int ErrorCode;
        public ulong JournalId; public long FirstUsn; public long NextUsn; public long MaxSize;
        public List<string> Reasons = new List<string>(); public List<string> Names = new List<string>();
        public int PrivErrorCode; public int MajorVersion; public long OldestFileTime; public List<string> Attempts = new List<string>();
    }

    static readonly KeyValuePair<uint, string>[] ReasonNames = new KeyValuePair<uint, string>[] {
        new KeyValuePair<uint, string>(0x1, "DATA_OVERWRITE"), new KeyValuePair<uint, string>(0x2, "DATA_EXTEND"), new KeyValuePair<uint, string>(0x4, "DATA_TRUNCATION"),
        new KeyValuePair<uint, string>(0x10, "NAMED_DATA_OVERWRITE"), new KeyValuePair<uint, string>(0x20, "NAMED_DATA_EXTEND"), new KeyValuePair<uint, string>(0x40, "NAMED_DATA_TRUNCATION"),
        new KeyValuePair<uint, string>(0x100, "FILE_CREATE"), new KeyValuePair<uint, string>(0x200, "FILE_DELETE"), new KeyValuePair<uint, string>(0x400, "EA_CHANGE"),
        new KeyValuePair<uint, string>(0x800, "SECURITY_CHANGE"), new KeyValuePair<uint, string>(0x1000, "RENAME_OLD_NAME"), new KeyValuePair<uint, string>(0x2000, "RENAME_NEW_NAME"),
        new KeyValuePair<uint, string>(0x4000, "INDEXABLE_CHANGE"), new KeyValuePair<uint, string>(0x8000, "BASIC_INFO_CHANGE"), new KeyValuePair<uint, string>(0x10000, "HARD_LINK_CHANGE"),
        new KeyValuePair<uint, string>(0x20000, "COMPRESSION_CHANGE"), new KeyValuePair<uint, string>(0x40000, "ENCRYPTION_CHANGE"), new KeyValuePair<uint, string>(0x80000, "OBJECT_ID_CHANGE"),
        new KeyValuePair<uint, string>(0x100000, "REPARSE_POINT_CHANGE"), new KeyValuePair<uint, string>(0x200000, "STREAM_CHANGE"), new KeyValuePair<uint, string>(0x80000000, "CLOSE") };

    static string ReasonText(uint r)
    {
        List<string> l = new List<string>();
        foreach (KeyValuePair<uint, string> kv in ReasonNames) if ((r & kv.Key) != 0) l.Add(kv.Value);
        return l.Count == 0 ? ("0x" + r.ToString("x")) : string.Join("|", l.ToArray());
    }

    // Thử từng kiểu handle từ quyền thấp nhất; mỗi kiểu chạy trọn chuỗi QUERY -> READ. Ghi lại từng lần thử để biết kiểu nào đủ.
    public static Result Probe(string drive, int maxRecords)
    {
        string vol = @"\\.\" + drive + ":"; string rootDir = drive + @":\";
        // Kiểu handle: thiết bị volume (không quyền / đọc thuộc tính / đọc) và thư mục gốc của ổ (cần FILE_FLAG_BACKUP_SEMANTICS để mở thư mục).
        string[] path = new string[] { vol, vol, vol, vol, rootDir, rootDir };
        uint[] acc = new uint[] { 0, 0x80, 0x80000000, 0x80000080, 0x80, 0x81 };
        uint[] flg = new uint[] { 0, 0, 0, 0, 0x02000000, 0x02000000 };
        string[] nm = new string[] { "vol:none", "vol:attr", "vol:read", "vol:read+attr", "rootdir:attr", "rootdir:list+attr" };
        List<string> attempts = new List<string>();
        Result best = null;
        for (int i = 0; i < acc.Length; i++)
        {
            IntPtr h = CreateFileW(path[i], acc[i], 7, IntPtr.Zero, 3, flg[i], IntPtr.Zero);
            if (h == (IntPtr)(-1))
            {
                int err = Marshal.GetLastWin32Error();
                attempts.Add(nm[i] + ": mở volume lỗi " + err);
                if (best == null) { best = new Result(); best.Error = "Không mở được volume " + vol + " (Win32 " + err + ")"; best.ErrorCode = err; }
                continue;
            }
            Result r = ProbeHandle(h, maxRecords);
            r.HandleAccess = nm[i];
            attempts.Add(nm[i] + ": " + (r.ReadOk ? "ok" : (r.QueryOk ? "query ok, read lỗi " + r.ErrorCode : "query lỗi " + r.ErrorCode)));
            if (r.QueryOk || best == null || best.HandleAccess == null) best = r;
            if (r.ReadOk) break;
        }
        best.Attempts = attempts;
        return best;
    }

    static Result ProbeHandle(IntPtr h, int maxRecords)
    {
        Result r = new Result();
        try
        {
            // FSCTL_QUERY_USN_JOURNAL = 0x900F4 -> USN_JOURNAL_DATA_V0 (không cần dữ liệu vào)
            byte[] q = new byte[80]; int ret;
            if (!DeviceIoControl(h, 0x900F4, null, 0, q, q.Length, out ret, IntPtr.Zero))
            {
                r.ErrorCode = Marshal.GetLastWin32Error(); r.Error = "FSCTL_QUERY_USN_JOURNAL lỗi (Win32 " + r.ErrorCode + ")"; return r;
            }
            r.QueryOk = true;
            r.JournalId = BitConverter.ToUInt64(q, 0); r.FirstUsn = BitConverter.ToInt64(q, 8); r.NextUsn = BitConverter.ToInt64(q, 16); r.MaxSize = BitConverter.ToInt64(q, 40);

            // READ_USN_JOURNAL_DATA_V1 (48 byte): StartUsn, ReasonMask, ReturnOnlyOnClose, Timeout, BytesToWaitFor, UsnJournalID, MinMajor, MaxMajor
            long start = r.FirstUsn;   // USN phải trùng ranh giới bản ghi: NextUsn - N (không căn ranh giới) cho lỗi 87, FirstUsn thì đọc được
            byte[] inb = BuildRead(start, r.JournalId);
            byte[] buf = new byte[1 << 20];

            // Thử bản không đặc quyền (0x903AB) trước; thử thêm bản đặc quyền (0x900BB) chỉ để so sánh.
            byte[] privBuf = new byte[1 << 16];
            if (DeviceIoControl(h, 0x900BB, inb, inb.Length, privBuf, privBuf.Length, out ret, IntPtr.Zero)) r.PrivReadOk = true; else r.PrivErrorCode = Marshal.GetLastWin32Error();

            if (!DeviceIoControl(h, 0x903AB, inb, inb.Length, buf, buf.Length, out ret, IntPtr.Zero))
            {
                r.ErrorCode = Marshal.GetLastWin32Error(); r.Error = "FSCTL_READ_UNPRIVILEGED_USN_JOURNAL lỗi (Win32 " + r.ErrorCode + ")"; return r;
            }
            r.ReadOk = true;
            int pos = 8;   // 8 byte đầu = USN kế tiếp
            while (pos + 60 <= ret && r.Records < maxRecords)
            {
                int len = BitConverter.ToInt32(buf, pos); if (len < 60 || pos + len > ret) break;
                int major = BitConverter.ToUInt16(buf, pos + 4); r.MajorVersion = major;
                // V2: Reason ở +40, FileNameLength +56, FileNameOffset +58. V3: FRN dài 16 byte nên Reason ở +56, tên ở +72/+74.
                uint reason; int nameLen, nameOff;
                if (major == 3) { reason = BitConverter.ToUInt32(buf, pos + 56); nameLen = BitConverter.ToUInt16(buf, pos + 72); nameOff = BitConverter.ToUInt16(buf, pos + 74); }
                else { reason = BitConverter.ToUInt32(buf, pos + 40); nameLen = BitConverter.ToUInt16(buf, pos + 56); nameOff = BitConverter.ToUInt16(buf, pos + 58); }
                if (r.Records == 0) r.OldestFileTime = BitConverter.ToInt64(buf, pos + (major == 3 ? 48 : 32));   // TimeStamp của bản ghi đầu = bản ghi cũ nhất còn trong journal
                r.Records++;
                if (nameLen > 0 && pos + nameOff + nameLen <= ret) { r.WithName++; if (r.Names.Count < 5) r.Names.Add(Encoding.Unicode.GetString(buf, pos + nameOff, nameLen)); }
                string rt = ReasonText(reason);
                if (r.Reasons.Count < 8 && !r.Reasons.Contains(rt)) r.Reasons.Add(rt);
                pos += len;
            }
            return r;
        }
        finally { CloseHandle(h); }
    }

    static byte[] BuildRead(long start, ulong journalId)
    {
        byte[] b = new byte[48];
        Array.Copy(BitConverter.GetBytes(start), 0, b, 0, 8);
        Array.Copy(BitConverter.GetBytes(0xFFFFFFFFu), 0, b, 8, 4);      // ReasonMask: tất cả
        Array.Copy(BitConverter.GetBytes(0u), 0, b, 12, 4);             // ReturnOnlyOnClose = 0
        Array.Copy(BitConverter.GetBytes(0UL), 0, b, 16, 8);            // Timeout
        Array.Copy(BitConverter.GetBytes(0UL), 0, b, 24, 8);            // BytesToWaitFor = 0: không chờ
        Array.Copy(BitConverter.GetBytes(journalId), 0, b, 32, 8);
        Array.Copy(BitConverter.GetBytes((ushort)2), 0, b, 40, 2);      // MinMajorVersion
        Array.Copy(BitConverter.GetBytes((ushort)3), 0, b, 42, 2);      // MaxMajorVersion
        return b;
    }
}
'@

$build = $null
try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch { $build = [Environment]::OSVersion.Version.Build }
$elevated = $false
try { $elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

$out = [ordered]@{ osBuild = $build; elevated = $elevated; drive = $Drive; handleAccess = $null; queryOk = $false; readOk = $false; records = 0; withName = 0; sampleReasons = @(); error = $null }
try {
    if ($Drive -notmatch '^[A-Z]$') { throw "Tên ổ không hợp lệ: '$Drive'" }
    $r = [RgUsnProbe]::Probe($Drive, 1000)
    $out.handleAccess = $r.HandleAccess; $out.queryOk = [bool]$r.QueryOk; $out.readOk = [bool]$r.ReadOk; $out.records = [int]$r.Records; $out.withName = [int]$r.WithName
    $out.sampleReasons = @($r.Reasons); $out.error = $r.Error
    $out['errorCode'] = [int]$r.ErrorCode; $out['privilegedReadOk'] = [bool]$r.PrivReadOk; $out['privilegedErrorCode'] = [int]$r.PrivErrorCode
    $out['attempts'] = @($r.Attempts); $out['recordMajorVersion'] = [int]$r.MajorVersion; $out['sampleNames'] = @($r.Names)
    if ($r.OldestFileTime -gt 0) { $ot = [datetime]::FromFileTimeUtc($r.OldestFileTime); $out['oldestRecordUtc'] = $ot.ToString('o'); $out['journalAgeHours'] = [math]::Round(((Get-Date).ToUniversalTime() - $ot).TotalHours, 1) }
    if ($r.QueryOk) { $out['journal'] = [ordered]@{ id = [string]$r.JournalId; firstUsn = $r.FirstUsn; nextUsn = $r.NextUsn; maxSizeBytes = $r.MaxSize } }
}
catch { $out.error = [string]$_.Exception.Message }

if ($Json) { Write-Output (ConvertTo-Json -InputObject $out -Depth 5 -Compress) }
else {
    "Windows build $($out.osBuild), admin: $($out.elevated), ổ $Drive"
    "Mở volume: $($out.handleAccess)   QUERY: $($out.queryOk)   READ_UNPRIVILEGED: $($out.readOk)"
    "Bản ghi: $($out.records), có tên file: $($out.withName), lý do mẫu: $($out.sampleReasons -join '; ')"
    if ($out.error) { "Lỗi: $($out.error)" }
}
exit 0
