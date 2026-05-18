Set-StrictMode -Version Latest

function Dockersw {
    <#
    .SYNOPSIS
        Switch Docker Desktop between Windows and Linux container mode.
    .DESCRIPTION
        Calls DockerCli.exe -SwitchDaemon and reports the new mode.
    #>
    [CmdletBinding()]
    param()

    $cli = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
    if (-not (Test-Path $cli)) {
        Write-Error "DockerCli.exe not found at $cli - is Docker Desktop installed?"
        return
    }

    try {
        & $cli -SwitchDaemon
        $os = docker version -f '{{.Server.Os}}' 2>$null
        Write-Host "Switched to $os containers." -ForegroundColor Green
    } catch {
        $os = docker version -f '{{.Server.Os}}' 2>$null
        Write-Error "Failed to switch daemon. Current mode: $os"
    }
}

Export-ModuleMember -Function Dockersw
