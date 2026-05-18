$commands = @{
    "register" = "Register-Repo"
    "rg"       = "Register-Repo"
    "list"     = "List-Repos"
    "ls"       = "List-Repos"
    "get"      = "Get-Repo"
    "go"       = "Go-Repo"
    "cd"       = "Go-Repo"
    "config"   = "Set-ConfigPath"
    "conf"     = "Set-ConfigPath"
    "cfg"      = "Set-ConfigPath"
    "make"     = "Make-Repo"
    "mk"       = "Make-Repo"
    "remove"   = "Remove-Repo"
    "delete"   = "Remove-Repo"
    "rename"   = "Rename-Repo"
    "mv"       = "Rename-Repo"
    "prune"    = "Prune-Repos"
}

# Per-invocation cache so multiple helpers don't re-parse the JSON file
$script:_repoListCache = $null

# Custom type for formatted output
Update-TypeData -TypeName 'Repo.Entry' -DefaultDisplayPropertySet @('Name', 'Path', 'Valid') -Force

function Repo {
    <#
    .SYNOPSIS
    A general repository management function that can handle various commands.

    .DESCRIPTION
    This function handles repository management commands, including registering,
    removing, listing, and navigating to repositories.

    .EXAMPLE
    Repo myproject
    Navigates to the 'myproject' repository.

    .EXAMPLE
    Repo register "MyRepo" "C:\path\to\repo"
    Registers a repository named 'MyRepo' with the specified path.

    .EXAMPLE
    Repo register
    Registers current directory using the folder name as the repo name.

    .EXAMPLE
    Repo ls
    Lists all registered repositories as objects (pipeable).

    .EXAMPLE
    Repo ls | Where-Object { -not $_.Valid }
    Find all repos with broken paths.

    .EXAMPLE
    Repo rename oldname newname
    Renames a registered repository.

    .EXAMPLE
    Repo prune
    Removes all repos with invalid paths.
    #>
    param (
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [Object[]]$Params
    )

    # Reset per-invocation cache at the top-level entry point
    $script:_repoListCache = $null

    # No arguments: list repos
    if ([string]::IsNullOrWhiteSpace($Command)) {
        List-Repos
        return
    }

    # If the argument isn't a known command, treat it as a repo name shortcut
    if (-not $commands.ContainsKey($Command)) {
        Go-Repo $Command
        return
    }

    & $commands[$Command] @Params
}

function New-RepoEntry {
    param ([string]$Name, [string]$Path)
    [PSCustomObject]@{
        PSTypeName = 'Repo.Entry'
        Name       = $Name
        Path       = $Path
        Valid      = (Test-Path $Path)
    }
}

function Find-SimilarRepos {
    param ([string]$Name)
    $Repos = Get-RepoList
    $suggestions = @()

    # Glob match: *name* anywhere in repo name
    $suggestions += $Repos.Keys | Where-Object { $_ -like "*$Name*" }

    # Levenshtein distance <= 2 for short names, <= 3 for longer
    $maxDist = if ($Name.Length -le 4) { 1 } elseif ($Name.Length -le 7) { 2 } else { 3 }
    foreach ($key in $Repos.Keys) {
        if ($key -notin $suggestions) {
            $dist = Get-LevenshteinDistance $Name $key
            if ($dist -le $maxDist) { $suggestions += $key }
        }
    }

    # Prefix match on path segments
    foreach ($entry in $Repos.GetEnumerator()) {
        if ($entry.Key -notin $suggestions) {
            $leaf = ($entry.Value -split '[/\\]')[-1]
            if ($leaf -like "*$Name*") { $suggestions += $entry.Key }
        }
    }

    return $suggestions | Select-Object -Unique
}

function Get-LevenshteinDistance {
    param ([string]$s, [string]$t)
    $n = $s.Length; $m = $t.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $d = [int[,]]::new($n + 1, $m + 1)
    for ($i = 0; $i -le $n; $i++) { $d.SetValue($i, $i, 0) }
    for ($j = 0; $j -le $m; $j++) { $d.SetValue($j, 0, $j) }
    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($s[$i - 1] -eq $t[$j - 1]) { 0 } else { 1 }
            $del = $d.GetValue($i - 1, $j) + 1
            $ins = $d.GetValue($i, $j - 1) + 1
            $sub = $d.GetValue($i - 1, $j - 1) + $cost
            $d.SetValue([Math]::Min([Math]::Min($del, $ins), $sub), $i, $j)
        }
    }
    return $d.GetValue($n, $m)
}

function Go-Repo {
    <#
    .SYNOPSIS
    Navigates to the directory of a specified repository and returns the path.
    #>
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$RepoName
    )

    $RepoPath = Get-RepoPath $RepoName
    if ($RepoPath -and (Test-Path $RepoPath)) {
        Set-Location $RepoPath
        return [System.IO.DirectoryInfo]$RepoPath
    } elseif (-not $RepoPath) {
        $similar = Find-SimilarRepos $RepoName
        if ($similar.Count -gt 0) {
            Write-Error "Repo '$RepoName' is not registered. Did you mean: $($similar -join ', ')?"
        } else {
            Write-Error "Repo '$RepoName' is not registered. Use 'Repo register $RepoName <path>' to register it."
        }
    } else {
        Write-Error "Repo '$RepoName' has an invalid path: '$RepoPath'."
    }
}

function Register-Repo {
    <#
    .SYNOPSIS
    Registers a repository with a name and path. Both parameters are optional -
    omit both to register the current directory using the folder name.
    #>
    param (
        [Parameter(Position = 0)]
        [string]$RepoName,

        [Parameter(Position = 1)]
        [string]$RepoPath
    )

    # No args: derive both from current directory
    if (-not $RepoName) {
        $RepoPath = (Get-Location).Path
        $RepoName = (Split-Path $RepoPath -Leaf).ToLower()
    } elseif (-not $RepoPath) {
        $RepoPath = (Get-Location).Path
    }

    $RepoName = $RepoName.ToLower()
    $RepoPath = $RepoPath -replace '\\', '/'

    if (-not (Test-Path -Path $RepoPath -PathType Container)) {
        Write-Error "Invalid path: '$RepoPath'. It must be a valid directory."
        return
    }

    if ($commands.ContainsKey($RepoName)) {
        Write-Error "Invalid repo name: '$RepoName'. Reserved names: $($commands.Keys -join ', ')"
        return
    }

    $Repos = Get-RepoList
    $isUpdate = $Repos.ContainsKey($RepoName)
    $Repos[$RepoName] = $RepoPath
    Set-RepoList $Repos

    $entry = New-RepoEntry $RepoName $RepoPath
    if ($isUpdate) {
        Write-Warning "Repo '$RepoName' updated to '$RepoPath'."
    } else {
        Write-Host "Repo '$RepoName' registered to '$RepoPath'." -ForegroundColor Green
    }
    return $entry
}

function Get-RepoPath {
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$RepoName
    )

    $RepoName = $RepoName.ToLower()
    $Repos = Get-RepoList
    return $Repos[$RepoName]
}

function Get-Repo {
    <#
    .SYNOPSIS
    Retrieves a registered repository as an object.
    #>
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$RepoName
    )

    $Path = Get-RepoPath $RepoName
    if ($Path) {
        return New-RepoEntry $RepoName $Path
    } else {
        $similar = Find-SimilarRepos $RepoName
        if ($similar.Count -gt 0) {
            Write-Error "Repo '$RepoName' is not registered. Did you mean: $($similar -join ', ')?"
        } else {
            Write-Error "Repo '$RepoName' is not registered."
        }
    }
}

function Get-RepoFilePath {
    # Explicit env var takes priority; otherwise use the standard config location.
    if ($Env:Repositories -and (Test-Path $Env:Repositories)) {
        return $Env:Repositories
    }
    $default = Join-Path $env:USERPROFILE '.config\pstools\repositories.json'
    return $default
}

function Get-RepoList {
    if ($script:_repoListCache) {
        return $script:_repoListCache
    }

    $repoFile = Get-RepoFilePath
    if (-not (Test-Path $repoFile)) {
        return @{ }
    }

    $Content = Get-Content -Path $repoFile -Raw -ErrorAction SilentlyContinue
    if (-not $Content) {
        return @{ }
    }

    try {
        $Object = $Content | ConvertFrom-Json -ErrorAction Stop
        $Hashtable = @{ }
        $Object.PSObject.Properties | ForEach-Object { $Hashtable[$_.Name.ToLower()] = $_.Value }
        $script:_repoListCache = $Hashtable
        return $Hashtable
    } catch {
        Write-Error "Repository file is invalid: $repoFile"
        return @{ }
    }
}

function List-Repos {
    <#
    .SYNOPSIS
    Lists all registered repositories as objects. Pipeable.

    .PARAMETER Relative
    Pass -r to show only repos under the current directory.
    #>
    param (
        [string]$Relative
    )

    $Repos = Get-RepoList
    if ($Repos.Count -eq 0) {
        Write-Warning "No repositories registered."
        return
    }

    if ($Relative -eq "Relative" -or $Relative -eq "/r" -or $Relative -eq "-r") {
        $NormalizedCurrentDir = ((Get-Location).Path -replace '\\', '/').TrimEnd('/')
        $FilteredRepos = @{}

        foreach ($entry in $Repos.GetEnumerator()) {
            $NormalizedRepoPath = ($entry.Value -replace '\\', '/').TrimEnd('/')
            if ($NormalizedRepoPath.StartsWith($NormalizedCurrentDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $FilteredRepos[$entry.Key] = $entry.Value
            }
        }

        $Repos = $FilteredRepos
    }

    if ($Repos.Count -eq 0) {
        Write-Warning "No repositories under current directory."
        return
    }

    $Repos.GetEnumerator() | Sort-Object { $_.Value } | ForEach-Object {
        New-RepoEntry $_.Key $_.Value
    }
}

function Set-RepoList {
    param (
        [Parameter(Position = 0, Mandatory)]
        [hashtable]$Repos
    )

    $repoFile = Get-RepoFilePath
    $repoDir = Split-Path $repoFile -Parent
    if (-not (Test-Path $repoDir)) {
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
    }

    try {
        $Json = $Repos | ConvertTo-Json -Compress
        Set-Content -Path $repoFile -Value $Json -Encoding UTF8 -Force
        $script:_repoListCache = $null
    } catch {
        Write-Error "Error saving repository list: $_"
    }
}

function Set-ConfigPath {
    <#
    .SYNOPSIS
    Migrates the repository data file to the standard config location.
    .DESCRIPTION
    Kept for backward compatibility. The default path is now ~/.config/pstools/repositories.json.
    If a custom path is given, its content is copied there and the Repositories env var is set.
    #>
    param (
        [Parameter(Position = 0)]
        [string]$Path
    )

    if (-not $Path) {
        Write-Host "Repository config: $(Get-RepoFilePath)" -ForegroundColor Cyan
        return
    }

    if (-not (Test-Path $Path)) {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -Path $Path -Value "{}" -Encoding UTF8
    }

    [System.Environment]::SetEnvironmentVariable("Repositories", $Path, [System.EnvironmentVariableTarget]::User)
    [System.Environment]::SetEnvironmentVariable("Repositories", $Path, [System.EnvironmentVariableTarget]::Process)
    $script:_repoListCache = $null
    Write-Host "Repository config set to '$Path'." -ForegroundColor Green
}

function Remove-Repo {
    <#
    .SYNOPSIS
    Removes a registered repository. Enter the command twice to confirm.
    #>
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$RepoName
    )

    $RepoName = $RepoName.ToLower()

    if ($global:LastRepoName -eq $RepoName) {
        Remove-InvalidRepo $RepoName
    } else {
        Write-Warning "To remove '$RepoName', enter the command again."
        $global:LastRepoName = $RepoName
    }
}

function Remove-InvalidRepo {
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$RepoName
    )

    $Repos = Get-RepoList
    if ($Repos.ContainsKey($RepoName)) {
        $Repos.Remove($RepoName)
        Set-RepoList $Repos
        Write-Host "Repo '$RepoName' removed." -ForegroundColor Green
    } else {
        Write-Error "Repo '$RepoName' does not exist."
    }

    $global:LastRepoName = $null
}

function Rename-Repo {
    <#
    .SYNOPSIS
    Renames a registered repository.

    .EXAMPLE
    Repo rename oldname newname
    #>
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$OldName,

        [Parameter(Position = 1, Mandatory)]
        [string]$NewName
    )

    $OldName = $OldName.ToLower()
    $NewName = $NewName.ToLower()

    if ($commands.ContainsKey($NewName)) {
        Write-Error "Invalid repo name: '$NewName'. Reserved names: $($commands.Keys -join ', ')"
        return
    }

    $Repos = Get-RepoList
    if (-not $Repos.ContainsKey($OldName)) {
        Write-Error "Repo '$OldName' does not exist."
        return
    }

    if ($Repos.ContainsKey($NewName)) {
        Write-Error "Repo '$NewName' already exists."
        return
    }

    $Path = $Repos[$OldName]
    $Repos.Remove($OldName)
    $Repos[$NewName] = $Path
    Set-RepoList $Repos

    Write-Host "Repo '$OldName' renamed to '$NewName'." -ForegroundColor Green
    return New-RepoEntry $NewName $Path
}

function Prune-Repos {
    <#
    .SYNOPSIS
    Removes all repos with invalid (non-existent) paths.
    #>
    $Repos = Get-RepoList
    if ($Repos.Count -eq 0) {
        Write-Warning "No repositories registered."
        return
    }

    $invalid = @()
    foreach ($entry in @($Repos.GetEnumerator())) {
        if (-not (Test-Path $entry.Value)) {
            $invalid += $entry.Key
        }
    }

    if ($invalid.Count -eq 0) {
        Write-Host "All $($Repos.Count) repos have valid paths." -ForegroundColor Green
        return
    }

    foreach ($name in $invalid) {
        Write-Warning "Removing '$name' -> $($Repos[$name])"
        $Repos.Remove($name)
    }

    Set-RepoList $Repos
    Write-Host "Pruned $($invalid.Count) repo(s) with invalid paths." -ForegroundColor Green
}

function Make-Repo {
    <#
    .SYNOPSIS
    Creates a new folder, registers it as a repo, and initializes a git repository.
    #>
    param (
        [Parameter(Position = 0, Mandatory)]
        [string]$FolderName
    )

    if ([System.IO.Path]::IsPathRooted($FolderName)) {
        $TargetPath = $FolderName
    } else {
        $TargetPath = Join-Path (Get-Location) $FolderName
    }

    if (Test-Path $TargetPath) {
        Write-Error "Folder '$TargetPath' already exists."
        return
    }

    try {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    } catch {
        Write-Error "Failed to create folder: $_"
        return
    }

    $RepoName = (Split-Path $TargetPath -Leaf).ToLower()
    Register-Repo $RepoName $TargetPath

    try {
        Set-Location $TargetPath
        git init 2>&1 | Out-Null
        Write-Host "Created and initialized '$RepoName' at '$TargetPath'." -ForegroundColor Green
    } catch {
        Write-Error "Failed to run 'git init': $_"
    }
}

# Native argument completer - bypasses filesystem fallback
Register-ArgumentCompleter -Native -CommandName Repo -ScriptBlock {
    param ($wordToComplete, $ast, $cursorPosition)
    $tokens = $ast.ToString() -split '\s+'
    # If we're on the second+ token and first token is a subcommand, complete repo names
    # If we're on the first token after 'repo', complete repo names (primary use case)
    $repos = Get-RepoList
    $repos.Keys | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $repos[$_])
    }
}

$global:LastRepoName = $null

Export-ModuleMember -Function Repo
