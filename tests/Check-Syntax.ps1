# Kiểm tra cú pháp nhanh, KHÔNG ghi file nào, không chạy code của dự án.
#   - Mọi *.ps1 trong scripts\ (kể cả scripts\spikes), rg.ps1 và tests\ : [Parser]::ParseFile
#   - Mọi ui\*.js : node --check (bỏ qua kèm cảnh báo nếu máy không có node)
# Chạy: pwsh -NoProfile -File tests\Check-Syntax.ps1   (hoặc powershell.exe). Thoát 1 nếu có lỗi.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$errors = 0; $checked = 0

$ps = @()
$ps += @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -Recurse -File)
$ps += @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' -File)
$rg = Join-Path $root 'rg.ps1'
if (Test-Path -LiteralPath $rg) { $ps += Get-Item -LiteralPath $rg }

foreach ($f in $ps) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    $checked++
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) { Write-Host ("  FAIL  {0}:{1}  {2}" -f $f.FullName.Substring($root.Length + 1), $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
        $errors += $errs.Count
    }
}
Write-Host ("PowerShell: {0} file đã phân tích" -f $checked)

$uiDir = Join-Path $root 'ui'
$js = @()
if (Test-Path -LiteralPath $uiDir) { $js = @(Get-ChildItem -LiteralPath $uiDir -Filter '*.js' -File) }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host 'WARN  không có node trong PATH: bỏ qua kiểm tra ui\*.js' -ForegroundColor Yellow
} else {
    foreach ($f in $js) {
        $ErrorActionPreference = 'Continue'   # PS 5.1: stderr của lệnh native qua 2>&1 thành ErrorRecord, không được ném
        $out = & $node.Source --check $f.FullName 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) {
            Write-Host ("  FAIL  ui\{0}" -f $f.Name) -ForegroundColor Red
            $out | ForEach-Object { Write-Host "        $_" }
            $errors++
        }
    }
    Write-Host ("JavaScript: {0} file đã kiểm" -f $js.Count)
}

if ($errors -gt 0) { Write-Host ("Check-Syntax: {0} lỗi" -f $errors) -ForegroundColor Red; exit 1 }
Write-Host 'Check-Syntax: OK'
exit 0
