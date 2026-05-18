Set-StrictMode -Version Latest

$script:ConfigDir  = Join-Path $env:USERPROFILE '.config\pstools'
$script:ConfigFile = Join-Path $script:ConfigDir 'silence.txt'
$script:DefaultTargets = @('w3wp', 'olk', 'ms-teams', 'sqlceip', 'sqlservr', 'sqlwriter', 'smartgit')

function Initialize-SilenceConfig {
    if (-not (Test-Path $script:ConfigFile)) {
        if (-not (Test-Path $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $script:DefaultTargets | Set-Content -Path $script:ConfigFile -Encoding utf8
    }
}

function Get-SilenceTargets {
    Initialize-SilenceConfig
    return @(Get-Content -Path $script:ConfigFile -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and $_ -notmatch '^\s*#' })
}

function Silence {
    <#
    .SYNOPSIS
        Kill a configurable list of noisy background processes.
    .DESCRIPTION
        Reads target process names from ~/.config/pstools/silence.txt (one per line).
        Creates the file with sensible defaults on first run.

        Use -List to show configured targets and their running state.
        Use -Add to add one or more targets. Use -Remove to remove them.
    .PARAMETER List
        Show all configured targets and whether they are currently running.
    .PARAMETER Add
        Add one or more process names to the target list.
    .PARAMETER Remove
        Remove one or more process names from the target list.
    .PARAMETER Quiet
        Suppress all output when killing processes.
    .EXAMPLE
        Silence
    .EXAMPLE
        Silence -List
    .EXAMPLE
        Silence -Add chrome, spotify
    .EXAMPLE
        Silence -Remove sqlwriter
    .EXAMPLE
        Silence -Verbose
    #>
    [CmdletBinding(DefaultParameterSetName='Kill')]
    param(
        [Parameter(ParameterSetName='List')]
        [switch]$List,

        [Parameter(Mandatory, ParameterSetName='Add', Position=0)]
        [string[]]$Add,

        [Parameter(Mandatory, ParameterSetName='Remove', Position=0)]
        [string[]]$Remove,

        [Parameter(ParameterSetName='Kill')]
        [switch]$Quiet
    )

    Initialize-SilenceConfig

    switch ($PSCmdlet.ParameterSetName) {
        'List' {
            $targets = Get-SilenceTargets
            if ($targets.Count -eq 0) {
                Write-Warning "No targets configured in $script:ConfigFile"
                return
            }
            Write-Host ""
            foreach ($t in $targets) {
                $procs = @(Get-Process -Name $t -ErrorAction SilentlyContinue)
                if ($procs.Count -gt 0) {
                    $mem = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0)
                    Write-Host "  $($t.PadRight(20))" -NoNewline -ForegroundColor White
                    Write-Host "running ($($procs.Count) instance(s), ~${mem} MB)" -ForegroundColor Green
                } else {
                    Write-Host "  $($t.PadRight(20))" -NoNewline -ForegroundColor DarkGray
                    Write-Host "not running" -ForegroundColor DarkGray
                }
            }
            Write-Host ""
        }
        'Add' {
            $targets = Get-SilenceTargets
            $added = @()
            foreach ($name in $Add) {
                $name = $name.Trim().TrimEnd(',')
                if ($name -eq '') { continue }
                if ($targets -contains $name) {
                    Write-Host "  '$name' already in target list" -ForegroundColor DarkGray
                } else {
                    Add-Content -Path $script:ConfigFile -Value $name -Encoding utf8
                    $added += $name
                }
            }
            if ($added.Count -gt 0) {
                Write-Host "  Added: $($added -join ', ')" -ForegroundColor Green
            }
        }
        'Remove' {
            $lines = @(Get-Content -Path $script:ConfigFile -ErrorAction Stop)
            $removed = @()
            foreach ($name in $Remove) {
                $name = $name.Trim().TrimEnd(',')
                if ($lines | Where-Object { $_.Trim() -eq $name }) {
                    $removed += $name
                } else {
                    Write-Host "  '$name' not found in target list" -ForegroundColor DarkYellow
                }
            }
            if ($removed.Count -gt 0) {
                $filtered = $lines | Where-Object { $removed -notcontains $_.Trim() }
                if ($filtered) { $filtered | Set-Content -Path $script:ConfigFile -Encoding utf8 }
                else { Set-Content -Path $script:ConfigFile -Value '' -Encoding utf8 }
                Write-Host "  Removed: $($removed -join ', ')" -ForegroundColor Yellow
            }
        }
        'Kill' {
            $targets = Get-SilenceTargets
            if ($targets.Count -eq 0) {
                if (-not $Quiet) { Write-Warning "No targets configured in $script:ConfigFile" }
                return
            }

            $timer = [Diagnostics.Stopwatch]::StartNew()
            $killed = 0
            $failed = $false

            foreach ($name in $targets) {
                $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
                if ($procs.Count -eq 0) {
                    Write-Verbose "No processes found for '$name'"
                    continue
                }
                foreach ($p in $procs) {
                    Write-Verbose "Killing $($p.ProcessName) (PID $($p.Id))"
                    try {
                        Stop-Process -Id $p.Id -Force -ErrorAction Stop
                        $killed++
                    } catch {
                        $failed = $true
                        Write-Verbose "Failed to kill PID $($p.Id): $_"
                    }
                }
            }

            $timer.Stop()
            if (-not $Quiet) {
                Write-Host "Stopped $killed process(es) in $([int]$timer.Elapsed.TotalMilliseconds)ms"
                if ($failed) {
                    Write-Warning "Some processes could not be killed. Try running as Administrator."
                }
            }
        }
    }
}

Export-ModuleMember -Function Silence
