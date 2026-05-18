Set-StrictMode -Version Latest

function Reset-IISCache {
    <#
    .SYNOPSIS
        Stop IIS, clear ASP.NET temp files, restart IIS.
    .DESCRIPTION
        Requires Administrator privileges. Removes Temporary ASP.NET Files
        for all .NET Framework versions under Framework64, then restarts IIS.
    #>
    [CmdletBinding()]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "This command requires Administrator privileges."
        return
    }

    if (-not (Get-Command iisreset -ErrorAction SilentlyContinue)) {
        Write-Error "iisreset not found - is IIS installed?"
        return
    }

    Write-Host "Stopping IIS..." -ForegroundColor Cyan
    iisreset /stop | Out-Null

    $tempPaths = @(Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\v*\Temporary ASP.NET Files' -Directory -ErrorAction SilentlyContinue)
    $cleared = 0
    foreach ($dir in $tempPaths) {
        $items = Get-ChildItem $dir.FullName -ErrorAction SilentlyContinue
        if ($items.Count -gt 0) {
            Remove-Item "$($dir.FullName)\*" -Recurse -Force -ErrorAction SilentlyContinue
            $cleared++
        }
    }

    Write-Host "Starting IIS..." -ForegroundColor Cyan
    iisreset /start | Out-Null

    if ($cleared -gt 0) {
        Write-Host "Cleared temp files from $cleared framework version(s) and restarted IIS." -ForegroundColor Green
    } else {
        Write-Host "No temp files to clear. IIS restarted." -ForegroundColor Green
    }
}

Export-ModuleMember -Function Reset-IISCache
