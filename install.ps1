# PsTools bootstrap installer
# Usage: irm https://raw.githubusercontent.com/Knyrps/pstools/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$repo   = 'Knyrps/pstools'
$module = 'PsTools'
$branch = 'main'
$base   = "https://raw.githubusercontent.com/$repo/$branch/modules/$module"
$target = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$module"

Write-Host "Installing PsTools..." -ForegroundColor Cyan

if (-not (Test-Path $target)) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

$files = @('PsTools.psd1', 'PsTools.psm1')
foreach ($f in $files) {
    $dest = Join-Path $target $f
    Invoke-WebRequest -Uri "$base/$f" -OutFile $dest -UseBasicParsing
    Write-Host "  $f" -ForegroundColor DarkGray
}

Write-Host "Installed to $target" -ForegroundColor Green
Write-Host ""
Write-Host "Run 'pstools' to open the interactive installer." -ForegroundColor Cyan
