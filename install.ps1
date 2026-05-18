# PsTools bootstrap installer
# Usage: irm https://raw.githubusercontent.com/Knyrps/pstools/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$repo   = 'Knyrps/pstools'
$module = 'PsTools'
$branch = 'main'
$target = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$module"

Write-Host "Installing PsTools..." -ForegroundColor Cyan

# Fetch file list from GitHub API
$apiUrl = "https://api.github.com/repos/$repo/contents/modules/$module?ref=$branch"
$files = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'PsTools-Installer' }

if (-not (Test-Path $target)) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

foreach ($f in $files) {
    if ($f.type -ne 'file') { continue }
    $dest = Join-Path $target $f.name
    Invoke-WebRequest -Uri $f.download_url -OutFile $dest -UseBasicParsing
    Write-Host "  $($f.name)" -ForegroundColor DarkGray
}

Write-Host "Installed to $target" -ForegroundColor Green
Write-Host ""
Write-Host "Run 'pstools' to open the interactive installer." -ForegroundColor Cyan
