Set-StrictMode -Version Latest

function Copy-FileContent {
    <#
    .SYNOPSIS
    Copies the contents of a file to the clipboard.
    .DESCRIPTION
    Reads a file and places its full content on the clipboard.
    Supports relative/absolute paths, environment variables, and ~ for the home directory.
    .EXAMPLE
    Copy-FileContent .\README.md
    .EXAMPLE
    Copy-FileContent $env:USERPROFILE\.gitconfig
    .EXAMPLE
    Copy-FileContent ~\.config\pstools\sources.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory)]
        [string]$Path
    )

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolved)) {
        Write-Error "File not found: $resolved"
        return
    }
    if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
        Write-Error "Path is a directory, not a file: $resolved"
        return
    }

    Get-Content -LiteralPath $resolved -Raw | Set-Clipboard
    Write-Host "Copied to clipboard: $resolved" -ForegroundColor Green
}

Set-Alias -Name cfc -Value Copy-FileContent -Scope Global
Export-ModuleMember -Function Copy-FileContent -Alias cfc
