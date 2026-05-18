Set-StrictMode -Version Latest

$script:DefaultRepoOwner = 'Knyrps'
$script:DefaultRepoName  = 'pstools'
$script:InstallDir = "$env:ProgramFiles\WindowsPowerShell\Modules"
$script:ConfigDir  = Join-Path $env:USERPROFILE '.config\pstools'
$script:SourcesFile = Join-Path $script:ConfigDir 'sources.json'

# ---------------------------------------------------------------------------
# Sources config
# ---------------------------------------------------------------------------

function Get-DefaultSource {
    return [PSCustomObject]@{
        Name = 'default'
        Type = 'github'
        Repo = "$script:DefaultRepoOwner/$script:DefaultRepoName"
        Path = 'modules'
    }
}

function Get-SourcesConfig {
    if (-not (Test-Path $script:SourcesFile)) { return @() }
    try {
        $raw = Get-Content -Path $script:SourcesFile -Raw -Encoding utf8
        $parsed = $raw | ConvertFrom-Json
        return @($parsed)
    } catch {
        return @()
    }
}

function Save-SourcesConfig {
    param([array]$Sources)
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
    # Force array wrapper in JSON even for single items
    $json = ConvertTo-Json -InputObject @($Sources) -Depth 5
    Set-Content -Path $script:SourcesFile -Value $json -Encoding utf8 -Force
}

function Get-AllSources {
    $custom = @(Get-SourcesConfig)
    $result = @(Get-DefaultSource)
    foreach ($s in $custom) { $result += $s }
    return $result
}

# ---------------------------------------------------------------------------
# Source: GitHub repo
# ---------------------------------------------------------------------------

function Get-GitHubModules {
    param([string]$Repo, [string]$SubPath)
    $apiUrl = "https://api.github.com/repos/$Repo/contents/$SubPath"
    try {
        $headers = @{ 'User-Agent' = 'PsTools/1.0' }
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        return @($resp | Where-Object { $_.type -eq 'dir' } | ForEach-Object { $_.name }) |
            Where-Object { $_ -ne 'PsTools' }
    } catch {
        Write-Warning "Failed to fetch from $Repo/$SubPath - $($_.Exception.Message)"
        return @()
    }
}

function Get-GitHubModuleFiles {
    param([string]$Repo, [string]$SubPath, [string]$ModuleName)
    $apiUrl = "https://api.github.com/repos/$Repo/contents/$SubPath/$ModuleName"
    try {
        $headers = @{ 'User-Agent' = 'PsTools/1.0' }
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        return @($resp | Where-Object { $_.type -eq 'file' })
    } catch {
        Write-Warning "Failed to list files for '$ModuleName' from $Repo"
        return @()
    }
}

function Install-GitHubModule {
    param([string]$Repo, [string]$SubPath, [string]$ModuleName)
    $targetDir = Join-Path $script:InstallDir $ModuleName
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $files = Get-GitHubModuleFiles $Repo $SubPath $ModuleName
    if ($files.Count -eq 0) { return $false }
    foreach ($file in $files) {
        try {
            Invoke-WebRequest -Uri $file.download_url -OutFile (Join-Path $targetDir $file.name) -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Error "Failed to download $($file.name): $($_.Exception.Message)"
            return $false
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Source: local folder
# ---------------------------------------------------------------------------

function Get-FolderModules {
    param([string]$FolderPath)
    if (-not (Test-Path $FolderPath)) {
        Write-Warning "Source folder not found: $FolderPath"
        return @()
    }
    return @(Get-ChildItem -Path $FolderPath -Directory |
        Where-Object { (Test-Path (Join-Path $_.FullName '*.psm1')) } |
        ForEach-Object { $_.Name }) |
        Where-Object { $_ -ne 'PsTools' }
}

function Install-FolderModule {
    param([string]$FolderPath, [string]$ModuleName)
    $sourceDir = Join-Path $FolderPath $ModuleName
    if (-not (Test-Path $sourceDir)) { return $false }
    $targetDir = Join-Path $script:InstallDir $ModuleName
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item "$sourceDir\*" $targetDir -Recurse -Force
    return $true
}

# ---------------------------------------------------------------------------
# Unified module discovery
# ---------------------------------------------------------------------------

function Get-AllModules {
    <#
    .SYNOPSIS Discover modules from all sources. Returns array of objects with Name, Source, SourceType, Installed.
    #>
    $sources = Get-AllSources
    $seen = @{}
    $result = @()

    foreach ($src in $sources) {
        $modules = @()
        switch ($src.Type) {
            'github' {
                $subPath = if ($src.Path) { $src.Path } else { 'modules' }
                $modules = Get-GitHubModules $src.Repo $subPath
            }
            'folder' {
                $modules = Get-FolderModules $src.Path
            }
        }
        foreach ($m in $modules) {
            if (-not $seen.ContainsKey($m)) {
                $seen[$m] = $true
                $result += [PSCustomObject]@{
                    Name       = $m
                    Source     = $src.Name
                    SourceType = $src.Type
                    SourceRef  = $src
                    Installed  = (Get-InstalledState $m)
                }
            }
        }
    }
    return $result
}

function Get-InstalledState {
    param([string]$ModuleName)
    return (Test-Path (Join-Path $script:InstallDir $ModuleName))
}

function Install-ModuleFromSource {
    param($ModuleInfo)
    switch ($ModuleInfo.SourceType) {
        'github' {
            $subPath = if ($ModuleInfo.SourceRef.Path) { $ModuleInfo.SourceRef.Path } else { 'modules' }
            return Install-GitHubModule $ModuleInfo.SourceRef.Repo $subPath $ModuleInfo.Name
        }
        'folder' {
            return Install-FolderModule $ModuleInfo.SourceRef.Path $ModuleInfo.Name
        }
    }
    return $false
}

function Uninstall-PSToolsModule {
    param([string]$ModuleName)
    $targetDir = Join-Path $script:InstallDir $ModuleName
    if (Test-Path $targetDir) {
        Remove-Item -Path $targetDir -Recurse -Force
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Interactive TUI
# ---------------------------------------------------------------------------

function Show-InstallerMenu {
    $ESC = [char]27

    Write-Host "  Fetching modules from all sources..." -ForegroundColor DarkGray
    $allModules = Get-AllModules
    if ($allModules.Count -eq 0) {
        Write-Error "No modules found from any source."
        return
    }

    $installed = [ordered]@{}
    $desired   = [ordered]@{}
    foreach ($m in $allModules) {
        $installed[$m.Name] = $m.Installed
        $desired[$m.Name]   = $m.Installed
    }

    $cursor = 0
    $done = $false
    $cancelled = $false
    $firstRender = $true
    $lastLineCount = 0

    try { [Console]::CursorVisible = $false } catch { }
    try {
        while (-not $done) {
            $keys = @($allModules | ForEach-Object { $_.Name })

            if ($firstRender) {
                $firstRender = $false
            } else {
                [Console]::Write("$ESC[${lastLineCount}A")
                [Console]::Write("$ESC[0J")
            }

            $linesWritten = 0
            $sourceCount = (Get-AllSources).Count
            Write-Host "  PsTools Installer  |  $sourceCount source(s)" -ForegroundColor Cyan
            Write-Host "  [Space] toggle  [Enter] apply  [Esc] cancel  [A] select all  [N] select none" -ForegroundColor DarkGray
            Write-Host ""
            $linesWritten += 3

            for ($i = 0; $i -lt $keys.Count; $i++) {
                $name = $keys[$i]
                $info = $allModules[$i]
                $isInstalled = $installed[$name]
                $wantInstalled = $desired[$name]
                $marker = if ($i -eq $cursor) { '>' } else { ' ' }
                $checkbox = if ($wantInstalled) { '[x]' } else { '[ ]' }
                $color = if ($wantInstalled) { 'Green' } else { 'DarkGray' }

                $changed = $installed[$name] -ne $desired[$name]
                $action = ''
                if ($changed) {
                    if ($wantInstalled) { $action = ' + install' }
                    else { $action = ' - uninstall' }
                }

                $statusTag = if ($isInstalled) { '(installed)' } else { '(available)' }
                $statusTag = $statusTag.PadRight(13)
                $sourceTag = "[$($info.Source)]"

                if ($i -eq $cursor) {
                    Write-Host "  $marker " -NoNewline -ForegroundColor Yellow
                    Write-Host "$checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$statusTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$name " -NoNewline -ForegroundColor White
                    Write-Host "$sourceTag" -NoNewline -ForegroundColor DarkGray
                    if ($action) { Write-Host $action -ForegroundColor $(if ($wantInstalled) { 'Green' } else { 'Red' }) }
                    else { Write-Host '' }
                } else {
                    Write-Host "  $marker $checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$statusTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$name " -NoNewline -ForegroundColor Gray
                    Write-Host "$sourceTag" -NoNewline -ForegroundColor DarkGray
                    if ($action) { Write-Host $action -ForegroundColor $(if ($wantInstalled) { 'Green' } else { 'Red' }) }
                    else { Write-Host '' }
                }
                $linesWritten++
            }
            $lastLineCount = $linesWritten

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $keys.Count - 1) { $cursor++ } }
                'Spacebar'  { $name = $keys[$cursor]; $desired[$name] = -not $desired[$name] }
                'A'         { foreach ($k in $keys) { $desired[$k] = $true } }
                'N'         { foreach ($k in $keys) { $desired[$k] = $false } }
                'Enter'     { $done = $true }
                'Escape'    { $done = $true; $cancelled = $true }
                default {
                    if ($key.Modifiers -band [ConsoleModifiers]::Control -and $key.Key -eq 'C') {
                        $done = $true; $cancelled = $true
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
    }

    if ($cancelled) {
        Write-Host "`n  Cancelled." -ForegroundColor DarkGray
        return
    }

    $toInstall   = @()
    $toUninstall = @()
    foreach ($m in $allModules) {
        if ($installed[$m.Name] -ne $desired[$m.Name]) {
            if ($desired[$m.Name]) { $toInstall += $m }
            else { $toUninstall += $m.Name }
        }
    }

    if ($toInstall.Count -eq 0 -and $toUninstall.Count -eq 0) {
        Write-Host "`n  No changes." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    foreach ($m in $toInstall) {
        Write-Host "  Installing $($m.Name) [$($m.Source)]..." -NoNewline -ForegroundColor Cyan
        $ok = Install-ModuleFromSource $m
        if ($ok) { Write-Host " done" -ForegroundColor Green }
        else { Write-Host " FAILED" -ForegroundColor Red }
    }
    foreach ($name in $toUninstall) {
        Write-Host "  Uninstalling $name..." -NoNewline -ForegroundColor Cyan
        $ok = Uninstall-PSToolsModule $name
        if ($ok) { Write-Host " done" -ForegroundColor Green }
        else { Write-Host " FAILED" -ForegroundColor Red }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Source management
# ---------------------------------------------------------------------------

function Invoke-SourceCommand {
    param([string[]]$Params)

    $sub = if ($Params.Count -gt 0) { $Params[0] } else { '' }

    switch ($sub) {
        'add' {
            if ($Params.Count -lt 3) {
                Write-Error "Usage: pstools source add <name> <github:owner/repo[:path]|folder:path>"
                return
            }
            $name = $Params[1]
            $spec = $Params[2]

            $sources = Get-SourcesConfig
            if ($sources | Where-Object { $_.Name -eq $name }) {
                Write-Error "Source '$name' already exists. Remove it first."
                return
            }

            $newSource = $null
            if ($spec -match '^folder:(.+)$') {
                $folderPath = $Matches[1]
                if (-not (Test-Path $folderPath)) {
                    Write-Error "Folder not found: $folderPath"
                    return
                }
                $newSource = [PSCustomObject]@{ Name = $name; Type = 'folder'; Path = $folderPath }
            }
            elseif ($spec -match '^github:([^:]+)(?::(.+))?$') {
                $repo = $Matches[1]
                $subPath = if ($Matches[2]) { $Matches[2] } else { 'modules' }
                $newSource = [PSCustomObject]@{ Name = $name; Type = 'github'; Repo = $repo; Path = $subPath }
            }
            elseif ($spec -match '^[a-zA-Z]:\\' -or $spec -match '^/' -or $spec -match '^\\\\') {
                # Bare path - treat as folder
                if (-not (Test-Path $spec)) {
                    Write-Error "Folder not found: $spec"
                    return
                }
                $newSource = [PSCustomObject]@{ Name = $name; Type = 'folder'; Path = $spec }
            }
            elseif ($spec -match '^[^/]+/[^/]+') {
                # Bare owner/repo - treat as github
                $newSource = [PSCustomObject]@{ Name = $name; Type = 'github'; Repo = $spec; Path = 'modules' }
            }
            else {
                Write-Error "Unrecognized source format. Use 'github:owner/repo[:path]', 'folder:path', a bare path, or 'owner/repo'."
                return
            }

            $sources += $newSource
            Save-SourcesConfig $sources
            Write-Host "  Source '$name' added ($($newSource.Type): $(if ($newSource.Type -eq 'github') { $newSource.Repo } else { $newSource.Path }))" -ForegroundColor Green
        }
        'remove' {
            if ($Params.Count -lt 2) {
                Write-Error "Usage: pstools source remove <name>"
                return
            }
            $name = $Params[1]
            $sources = Get-SourcesConfig
            $filtered = @($sources | Where-Object { $_.Name -ne $name })
            if ($filtered.Count -eq $sources.Count) {
                Write-Error "Source '$name' not found."
                return
            }
            Save-SourcesConfig $filtered
            Write-Host "  Source '$name' removed." -ForegroundColor Green
        }
        'list' {
            $all = Get-AllSources
            Write-Host ""
            foreach ($s in $all) {
                $ref = switch ($s.Type) {
                    'github' { "$($s.Repo)/$($s.Path)" }
                    'folder' { $s.Path }
                }
                $isDefault = if ($s.Name -eq 'default') { ' (built-in)' } else { '' }
                Write-Host "  $($s.Name.PadRight(15)) " -NoNewline -ForegroundColor Cyan
                Write-Host "$($s.Type.PadRight(8)) " -NoNewline -ForegroundColor DarkCyan
                Write-Host "$ref$isDefault"
            }
            Write-Host ""
        }
        default {
            Write-Host "  Usage:" -ForegroundColor Cyan
            Write-Host "    pstools source list                                    List all sources"
            Write-Host "    pstools source add <name> <owner/repo>                 Add GitHub source"
            Write-Host "    pstools source add <name> github:owner/repo[:path]     Add GitHub source (explicit)"
            Write-Host "    pstools source add <name> folder:C:\path\to\modules    Add local folder source"
            Write-Host "    pstools source add <name> C:\path\to\modules           Add local folder source (bare path)"
            Write-Host "    pstools source remove <name>                           Remove a source"
        }
    }
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function Invoke-PsTools {
    <#
    .SYNOPSIS
        PsTools - manage custom PowerShell modules from multiple sources.
    .DESCRIPTION
        Without parameters or with 'install', opens an interactive installer.
        Use 'list' to show available modules and their install state.
        Use 'update' to re-download all installed modules.
        Use 'source' to manage module sources (GitHub repos, local folders).
    .EXAMPLE
        pstools
    .EXAMPLE
        pstools source add work github:myorg/ps-modules
    .EXAMPLE
        pstools source add local folder:D:\MyModules
    .EXAMPLE
        pstools source list
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [string[]]$Params
    )

    switch ($Command) {
        'install' { Show-InstallerMenu }
        'list' {
            Write-Host "  Fetching modules from all sources..." -ForegroundColor DarkGray
            $allModules = Get-AllModules
            if ($allModules.Count -eq 0) { return }
            Write-Host ""
            foreach ($m in $allModules) {
                $status = if ($m.Installed) { 'installed' } else { 'available' }
                $color  = if ($m.Installed) { 'Green' } else { 'DarkGray' }
                Write-Host "  $($status.PadRight(12)) " -NoNewline -ForegroundColor $color
                Write-Host "$($m.Name.PadRight(20)) " -NoNewline
                Write-Host "[$($m.Source)]" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
        'update' {
            Write-Host "  Fetching modules from all sources..." -ForegroundColor DarkGray
            $allModules = Get-AllModules
            $updated = 0
            foreach ($m in $allModules) {
                if ($m.Installed) {
                    Write-Host "  Updating $($m.Name) [$($m.Source)]..." -NoNewline -ForegroundColor Cyan
                    $ok = Install-ModuleFromSource $m
                    if ($ok) { Write-Host " done" -ForegroundColor Green; $updated++ }
                    else { Write-Host " FAILED" -ForegroundColor Red }
                }
            }
            if ($updated -eq 0) { Write-Host "  No modules installed to update." -ForegroundColor DarkGray }
            else { Write-Host "  Updated $updated module(s)." -ForegroundColor Green }
        }
        'source' {
            Invoke-SourceCommand $Params
        }
        default {
            Show-InstallerMenu
        }
    }
}

New-Alias -Name pstools -Value Invoke-PsTools -Force

Export-ModuleMember -Function Invoke-PsTools -Alias pstools
