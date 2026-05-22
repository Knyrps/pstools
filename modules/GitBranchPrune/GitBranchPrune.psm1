Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Prune local git branches whose upstream is gone and which haven't been
    updated in a while.

.DESCRIPTION
    Runs `git fetch --all --prune` to refresh remote-tracking refs, then
    enumerates local branches via `git for-each-ref` and selects those that:
      - are not in the protected list (default: main, master, develop),
      - have a last commit date older than -MonthsOld months,
      - have an upstream marked [gone] (i.e. the tracked remote branch was
        deleted).

    By default the function only lists candidates (dry run). Pass -Delete to
    actually run `git branch -D` on each match. Pass -SkipFetch to skip the
    initial fetch.

.PARAMETER MonthsOld
    Minimum age (in months) of the last commit on the branch for it to be
    considered stale. Default: 6.

.PARAMETER Protected
    Branch names that will never be deleted, regardless of other criteria.
    Default: main, master, develop.

.PARAMETER RepoPath
    Optional path to the git repository. Defaults to the current directory.

.PARAMETER Delete
    Actually delete matching branches with `git branch -D`. Omit for a dry run.

.PARAMETER SkipFetch
    Skip `git fetch --all --prune`. Useful if you just fetched.

.EXAMPLE
    Invoke-GitBranchPrune
    Dry run with defaults (6 months, fetch first).

.EXAMPLE
    Invoke-GitBranchPrune -MonthsOld 2
    Dry run, 2-month cutoff.

.EXAMPLE
    Invoke-GitBranchPrune -MonthsOld 2 -Delete
    Actually delete branches older than 2 months whose upstream is gone.

.EXAMPLE
    Invoke-GitBranchPrune -RepoPath D:\Repos\foo -Protected main,master,develop,release -Delete
#>
function Invoke-GitBranchPrune {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [int]      $MonthsOld = 6,
        [string[]] $Protected = @('main', 'master', 'develop'),
        [string]   $RepoPath,
        [switch]   $Delete,
        [switch]   $SkipFetch
    )

    $startLocation = Get-Location
    try {
        if ($RepoPath) {
            if (-not (Test-Path -LiteralPath $RepoPath)) {
                Write-Error "RepoPath '$RepoPath' does not exist."
                return
            }
            Set-Location -LiteralPath $RepoPath
        }

        $null = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Not inside a git repository: $(Get-Location)"
            return
        }

        if (-not $SkipFetch) {
            Write-Verbose "Running git fetch --all --prune..."
            git fetch --all --prune | Out-Null
        }

        $cutoff = (Get-Date).AddMonths(-$MonthsOld)
        $candidates = @()

        git for-each-ref --format='%(refname:short)|%(committerdate:iso8601)|%(upstream:track)' refs/heads |
            ForEach-Object {
                $name, $date, $track = $_ -split '\|'
                if ($Protected -notcontains $name -and
                    [datetime]$date -lt $cutoff -and
                    $track -match '\[gone\]') {
                    $candidates += [PSCustomObject]@{
                        Branch     = $name
                        LastCommit = [datetime]$date
                        Track      = $track
                    }
                }
            }

        if ($candidates.Count -eq 0) {
            Write-Host "No branches match the criteria (older than $MonthsOld months and upstream gone)."
            return
        }

        $candidates | Sort-Object LastCommit | Format-Table -AutoSize | Out-Host
        Write-Host "Total: $($candidates.Count)"

        if (-not $Delete) {
            Write-Host "Dry run - pass -Delete to actually remove these branches." -ForegroundColor Yellow
            return $candidates
        }

        foreach ($c in $candidates) {
            if ($PSCmdlet.ShouldProcess($c.Branch, 'git branch -D')) {
                git branch -D $c.Branch
            }
        }
    }
    finally {
        Set-Location -LiteralPath $startLocation
    }
}

Set-Alias -Name gprune -Value Invoke-GitBranchPrune -Scope Global
Export-ModuleMember -Function Invoke-GitBranchPrune -Alias gprune
