# rm-probe.ps1 - SPIKE (C1): Restart Manager (rstrtmgr.dll) có cho biết TIẾN TRÌNH NÀO đang giữ một file/thư mục không, không cần admin?
# Chỉ ĐỌC: RmStartSession -> RmRegisterResources(đường dẫn) -> RmGetList -> RmEndSession. KHÔNG gọi RmShutdown/RmRestart, không đóng/kết thúc gì.
# Tự kiểm bằng file tạm trong %TEMP% (xoá cuối): không ai giữ / chính process này giữ / process con giữ / giữ độc quyền (FileShare.None) / thư mục.
# Kết quả JSON: { osBuild, elevated, idleOk, selfHolds, childHolds, exclusiveHolds, dirHolds, dirError, avgMs, ... }. Thất bại của API là KẾT QUẢ HỢP LỆ: luôn thoát 0.
#   -Path <file|dir>  : chỉ dò đường dẫn đó (không tự kiểm), in danh sách process đang giữ.
[CmdletBinding()]
param([string]$Path = '', [switch]$Json)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class RgRmProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, out uint lpdwRebootReasons);

    public class Holder { public int Pid; public string Name; public string Service; public string Type; public long StartFileTime; }
    public class Result { public int Code; public string Step; public List<Holder> Holders = new List<Holder>(); public long Ms; }

    static string TypeName(int t)
    {
        switch (t) { case 0: return "unknown"; case 1: return "mainwindow"; case 2: return "otherwindow"; case 3: return "service"; case 4: return "explorer"; case 5: return "console"; case 1000: return "critical"; default: return "type" + t; }
    }

    public static Result Probe(string[] files)
    {
        Result r = new Result();
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        uint h;
        StringBuilder key = new StringBuilder(33);
        int rc = RmStartSession(out h, 0, key);
        if (rc != 0) { r.Code = rc; r.Step = "RmStartSession"; return r; }
        try
        {
            rc = RmRegisterResources(h, (uint)files.Length, files, 0, null, 0, null);
            if (rc != 0) { r.Code = rc; r.Step = "RmRegisterResources"; return r; }
            uint needed = 0, count = 0, reasons = 0;
            rc = RmGetList(h, out needed, ref count, null, out reasons);
            if (rc == 0) { r.Code = 0; r.Step = "none"; return r; }   // không ai giữ
            if (rc != 234) { r.Code = rc; r.Step = "RmGetList(size)"; return r; }
            RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed + 4];
            count = (uint)info.Length;
            rc = RmGetList(h, out needed, ref count, info, out reasons);
            if (rc != 0) { r.Code = rc; r.Step = "RmGetList(data)"; return r; }
            for (int i = 0; i < count; i++)
            {
                Holder x = new Holder();
                x.Pid = info[i].Process.dwProcessId; x.Name = info[i].strAppName; x.Service = info[i].strServiceShortName; x.Type = TypeName(info[i].ApplicationType);
                x.StartFileTime = ((long)info[i].Process.ProcessStartTime.dwHighDateTime << 32) | (uint)info[i].Process.ProcessStartTime.dwLowDateTime;
                r.Holders.Add(x);
            }
            r.Code = 0; r.Step = "ok";
            return r;
        }
        finally { RmEndSession(h); r.Ms = sw.ElapsedMilliseconds; }
    }
}
'@

function Invoke-Probe([string]$P) {
    $r = [RgRmProbe]::Probe([string[]]@($P))
    return [pscustomobject]@{
        code = $r.Code; step = $r.Step; ms = $r.Ms
        holders = @($r.Holders | ForEach-Object { [pscustomobject]@{ pid = $_.Pid; name = $_.Name; service = $_.Service; type = $_.Type; startUtc = ([datetime]::FromFileTimeUtc($_.StartFileTime)).ToString('yyyyMMddTHHmmss') + 'Z' } })
    }
}

$elevated = $false
try { $elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
$out = [ordered]@{ osBuild = [Environment]::OSVersion.Version.ToString(); elevated = $elevated }

if ($Path) {
    $p = Invoke-Probe $Path
    $out.path = $Path; $out.result = $p
    if ($Json) { $out | ConvertTo-Json -Depth 5 } else { "code=$($p.code) step=$($p.step) ms=$($p.ms)"; $p.holders | Format-Table -AutoSize | Out-String }
    exit 0
}

$dir = Join-Path ([IO.Path]::GetTempPath()) ('rg-rm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Force -Path $dir)
$child = $null
try {
    $f = Join-Path $dir 'probe.txt'; [IO.File]::WriteAllText($f, 'x')
    $idle = Invoke-Probe $f
    $out.idleOk = ($idle.code -eq 0 -and $idle.holders.Count -eq 0); $out.idleMs = $idle.ms

    $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'ReadWrite')
    try { $self = Invoke-Probe $f } finally { $fs.Dispose() }
    $out.selfHolds = [bool]($self.holders | Where-Object { $_.pid -eq $PID }); $out.selfCode = $self.code; $out.selfHolders = @($self.holders | ForEach-Object { "$($_.pid):$($_.name)" })

    $f2 = Join-Path $dir 'child.txt'; [IO.File]::WriteAllText($f2, 'x')
    $exe = (Get-Process -Id $PID).Path
    $cmd = '$s=[IO.File]::Open(''' + $f2 + ''',''Open'',''ReadWrite'',''ReadWrite''); Start-Sleep -Seconds 60'
    $child = Start-Process $exe -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Hidden -PassThru
    $seen = $null
    for ($i = 0; $i -lt 40 -and -not $seen; $i++) {
        Start-Sleep -Milliseconds 250
        $c = Invoke-Probe $f2
        $seen = @($c.holders | Where-Object { $_.pid -eq $child.Id }) | Select-Object -First 1
    }
    $out.childHolds = [bool]$seen; $out.childType = $(if ($seen) { $seen.type } else { $null }); $out.childName = $(if ($seen) { $seen.name } else { $null })
    $out.childStartMatches = $false
    if ($seen) { $cp = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)"; $out.childStartMatches = ($seen.startUtc -eq (([datetime]$cp.CreationDate).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z')) }
    Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue; $child = $null

    $f3 = Join-Path $dir 'excl.txt'; [IO.File]::WriteAllText($f3, 'x')
    $fx = [IO.File]::Open($f3, 'Open', 'ReadWrite', 'None')
    try { $ex = Invoke-Probe $f3 } finally { $fx.Dispose() }
    $out.exclusiveHolds = [bool]($ex.holders | Where-Object { $_.pid -eq $PID })

    # thư mục: RM làm việc theo file; giữ một handle bên trong thư mục có làm thư mục "bị giữ" không?
    $sub = Join-Path $dir 'sub'; [void](New-Item -ItemType Directory -Path $sub); $f4 = Join-Path $sub 'inner.txt'; [IO.File]::WriteAllText($f4, 'x')
    $fi = [IO.File]::Open($f4, 'Open', 'ReadWrite', 'ReadWrite')
    try { $dr = Invoke-Probe $sub } finally { $fi.Dispose() }
    $out.dirHolds = [bool]($dr.holders | Where-Object { $_.pid -eq $PID }); $out.dirCode = $dr.code; $out.dirStep = $dr.step

    # thời gian trung bình một lần hỏi (file không ai giữ), 20 lần
    $t = [Diagnostics.Stopwatch]::StartNew(); 1..20 | ForEach-Object { [void](Invoke-Probe $f) }; $out.avgMs = [math]::Round($t.ElapsedMilliseconds / 20.0, 1)
    # Zone.Identifier (nguồn tải): ADS có đọc/ghi được bằng PS 5.1 không, và file sao chép/nén có giữ không
    try {
        $z = Join-Path $dir 'zone.txt'; [IO.File]::WriteAllText($z, 'x')
        Set-Content -LiteralPath $z -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.invalid/a.zip"
        $zr = @(Get-Content -LiteralPath $z -Stream 'Zone.Identifier' -ErrorAction Stop)
        $out.zoneReadable = ($zr -contains 'ZoneId=3'); $out.zoneHostUrl = [string](($zr | Where-Object { $_ -like 'HostUrl=*' }) | Select-Object -First 1)
        $zc = Join-Path $dir 'zone-copy.txt'; Copy-Item -LiteralPath $z -Destination $zc
        $out.zoneSurvivesCopy = [bool](Get-Item -LiteralPath $zc -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
    } catch { $out.zoneError = [string]$_.Exception.Message }

    # last-access time: hệ thống có cập nhật khi đọc không? (fsutil: 0/1 = bật, 2/3 = tắt; bit 0x80000000 = do hệ thống quản lý)
    try {
        $fu = (& fsutil behavior query disablelastaccess 2>&1 | Out-String).Trim(); $out.disableLastAccess = $fu
        $a = Join-Path $dir 'atime.txt'; [IO.File]::WriteAllText($a, 'x')
        $old = (Get-Date).AddDays(-40); (Get-Item -LiteralPath $a).LastAccessTime = $old
        [void][IO.File]::ReadAllText($a); Start-Sleep -Milliseconds 300
        $now = (Get-Item -LiteralPath $a).LastAccessTime
        $out.atimeUpdatedOnRead = ($now -gt $old.AddDays(1))
    } catch { $out.atimeError = [string]$_.Exception.Message }

    $out.verdict = if ($out.idleOk -and $out.selfHolds -and $out.childHolds) { 'usable' } else { 'not-usable' }
}
catch { $out.error = [string]$_.Exception.Message; $out.verdict = 'error' }
finally {
    if ($child) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($Json) { $out | ConvertTo-Json -Depth 5 } else { $out.GetEnumerator() | ForEach-Object { '{0,-18} {1}' -f $_.Key, $_.Value } }
exit 0
