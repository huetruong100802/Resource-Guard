# Đo overhead của watcher: chạy N tick thật (trong sandbox AGENT_RESOURCE_HOME riêng, chỉ ghi vào thư mục tạm),
# in thời gian mỗi tick và CPU/RAM của process. Thoát 1 nếu trung bình mỗi tick vượt -MaxAvgMs.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Bench-Watcher.ps1 [-Ticks 5] [-MaxAvgMs 5000] [-Json]
[CmdletBinding()]
param([int]$Ticks = 5, [int]$MaxAvgMs = 5000, [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("rg-bench-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Force -Path $sandbox)
$env:AGENT_RESOURCE_HOME = $sandbox
try {
    . (Join-Path $root 'scripts\rg-watcher.ps1')   # dot-source: chỉ nạp hàm
    for ($i = 0; $i -lt $Ticks; $i++) { [void](Invoke-RgWatchTick -NoToast) }
    $o = Get-RgWatcherOverhead
    if ($Json) { $o | ConvertTo-Json -Compress }
    else { "ticks=$($o.samples) avg=$($o.avgTickMs)ms p95=$($o.p95TickMs)ms max=$($o.maxTickMs)ms cpu/tick=$($o.cpuSecPerTick)s (~$($o.estCpuPctAtInterval)% một lõi ở chu kỳ mặc định) ram=$($o.workingSetMB)MB" }
    if ($o.avgTickMs -gt $MaxAvgMs) { Write-Host "Vượt ngưỡng $MaxAvgMs ms mỗi tick." -ForegroundColor Red; exit 1 }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_RESOURCE_HOME -ErrorAction SilentlyContinue
}
exit 0
