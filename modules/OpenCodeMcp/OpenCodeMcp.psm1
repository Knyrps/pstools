Set-StrictMode -Version Latest

function Get-ConfigPaths {
    $global = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
    if (-not (Test-Path $global)) {
        $global = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    }
    $local = $null
    foreach ($name in @('opencode.jsonc', 'opencode.json')) {
        $candidate = Join-Path (Get-Location) $name
        if (Test-Path $candidate) { $local = $candidate; break }
    }
    return @{ Global = $global; Local = $local }
}

function Read-JsoncFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw -Encoding utf8

    # Strip a stray UTF-8 BOM character if Get-Content didn't peel it off.
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }

    # JSONC is JSON + comments + trailing commas. Strict JSON parsers (notably
    # ConvertFrom-Json in Windows PowerShell 5.1) reject both, so we normalise.

    # Strip /* block comments */ first so we don't accidentally treat // inside
    # them as line comments.
    $stripped = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')

    # Strip // line comments, but only when // appears outside a string. Walk
    # the text once tracking whether we are inside a "..." string, and cut from
    # // to end-of-line when we're not.
    $sb = [System.Text.StringBuilder]::new($stripped.Length)
    $inString = $false
    $escape = $false
    $i = 0
    while ($i -lt $stripped.Length) {
        $c = $stripped[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $stripped.Length -and $stripped[$i + 1] -eq '/') {
            # Skip to end-of-line
            while ($i -lt $stripped.Length -and $stripped[$i] -ne "`n") { $i++ }
            continue
        }
        [void]$sb.Append($c); $i++
    }
    $stripped = $sb.ToString()

    # Strip trailing commas: a comma followed by optional whitespace then } or ].
    $stripped = [regex]::Replace($stripped, ',(\s*[}\]])', '$1')

    try { return $stripped | ConvertFrom-Json } catch { return $null }
}

function Write-JsoncPreservingComments([string]$Path, [hashtable]$McpStates) {
    # Re-read the raw file and only flip "enabled": true/false lines
    $lines = Get-Content -Path $Path -Encoding utf8
    $currentMcp = $null
    $braceDepth = 0
    $inMcpBlock = $false
    $mcpEntryDepth = 0
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        # Detect top-level "mcp" key
        if ($line -match '^\s*"mcp"\s*:\s*\{') { $inMcpBlock = $true; $braceDepth = 1; $result.Add($line); continue }

        if ($inMcpBlock) {
            # Count braces before processing
            $prevDepth = $braceDepth
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq '{') { $braceDepth++ }
                elseif ($ch -eq '}') { $braceDepth-- }
            }
            if ($braceDepth -le 0) { $inMcpBlock = $false; $currentMcp = $null; $result.Add($line); continue }

            # Detect MCP server name: only at depth 1 (direct child of "mcp")
            if ($prevDepth -eq 1 -and $line -match '^\s*"([^"]+)"\s*:\s*\{') {
                $currentMcp = $Matches[1]
                $mcpEntryDepth = $braceDepth
            }

            # Reset currentMcp when we exit its block
            if ($currentMcp -and $braceDepth -lt $mcpEntryDepth) {
                $currentMcp = $null
            }

            # Flip enabled value only at the MCP entry's direct level (not nested objects)
            if ($currentMcp -and $McpStates.ContainsKey($currentMcp) -and $braceDepth -eq $mcpEntryDepth -and $line -match '^\s*"enabled"\s*:') {
                $newVal = if ($McpStates[$currentMcp]) { 'true' } else { 'false' }
                $line = $line -replace '(:\s*)(true|false)', "`${1}$newVal"
            }
        }
        $result.Add($line)
    }

    $result | Set-Content -Path $Path -Encoding utf8
}

function Get-McpServers([string]$Path) {
    $config = Read-JsoncFile $Path
    if (-not $config -or -not $config.mcp) { return @{} }
    $servers = [ordered]@{}
    foreach ($prop in $config.mcp.PSObject.Properties) {
        $enabled = $true
        if ($null -ne $prop.Value.enabled) { $enabled = [bool]$prop.Value.enabled }
        $type = if ($prop.Value.type) { $prop.Value.type } else { '?' }
        $servers[$prop.Name] = @{ Enabled = $enabled; Type = $type }
    }
    return $servers
}

function Show-InteractiveMenu {
    param(
        [System.Collections.IDictionary]$GlobalServers,
        [System.Collections.IDictionary]$LocalServers,
        [string]$GlobalPath,
        [string]$LocalPath
    )

    # ESC char — `e literal only works in PowerShell 6+, so use [char]27 for WinPS 5.1 compatibility.
    $ESC = [char]27

    $hasLocal = $null -ne $LocalPath -and $LocalServers.Count -gt 0
    $scopes = @('Global')
    if ($hasLocal) { $scopes = @('Global', 'Local') }
    $scopeIdx = 0

    # Clone states for editing
    $globalStates = [ordered]@{}
    foreach ($k in $GlobalServers.Keys) { $globalStates[$k] = $GlobalServers[$k].Enabled }
    $localStates = [ordered]@{}
    if ($hasLocal) { foreach ($k in $LocalServers.Keys) { $localStates[$k] = $LocalServers[$k].Enabled } }

    # Track original states to detect changes
    $globalOrig = [ordered]@{}; foreach ($k in $GlobalServers.Keys) { $globalOrig[$k] = $GlobalServers[$k].Enabled }
    $localOrig  = [ordered]@{}; if ($hasLocal) { foreach ($k in $LocalServers.Keys) { $localOrig[$k] = $LocalServers[$k].Enabled } }

    $cursor = 0
    $done = $false
    $cancelled = $false
    $firstRender = $true
    $lastLineCount = 0

    try { [Console]::CursorVisible = $false } catch { }
    try {
        while (-not $done) {
            $currentStates = if ($scopeIdx -eq 0) { $globalStates } else { $localStates }
            $currentServers = if ($scopeIdx -eq 0) { $GlobalServers } else { $LocalServers }
            $keys = @($currentStates.Keys)

            if ($cursor -ge $keys.Count) { $cursor = [Math]::Max(0, $keys.Count - 1) }

            # Render: on first paint, just print. On subsequent paints, move the cursor
            # back up over the previous block and overwrite it. This avoids
            # [Console]::Clear() entirely, which behaves poorly with large scrollback
            # buffers on Windows Terminal.
            if ($firstRender) {
                $firstRender = $false
            } else {
                # ANSI: move cursor up N lines, then clear from cursor down.
                # Use [char]27 ("$ESC") because `e is PS6+ only and renders literal in WinPS 5.1.
                [Console]::Write("$ESC[${lastLineCount}A")
                [Console]::Write("$ESC[0J")
            }

            $linesWritten = 0
            $scopeLabel = $scopes[$scopeIdx]
            $tabHint = if ($scopes.Count -gt 1) { "  [Tab] switch scope" } else { "" }
            $localTag = if ($hasLocal -and $scopeIdx -eq 0) { " (local overrides exist)" } else { "" }
            Write-Host "  Toggle-OCMcp  |  Scope: " -NoNewline
            Write-Host "$scopeLabel$localTag" -ForegroundColor Cyan
            Write-Host "  [Space] toggle  [Enter] save  [Esc] cancel$tabHint" -ForegroundColor DarkGray
            Write-Host ""
            $linesWritten += 3

            for ($i = 0; $i -lt $keys.Count; $i++) {
                $name = $keys[$i]
                $enabled = $currentStates[$name]
                $type = $currentServers[$name].Type
                $marker = if ($i -eq $cursor) { '>' } else { ' ' }
                $checkbox = if ($enabled) { '[x]' } else { '[ ]' }
                $color = if ($enabled) { 'Green' } else { 'DarkGray' }

                # Check if this was changed
                $origStates = if ($scopeIdx -eq 0) { $globalOrig } else { $localOrig }
                $changed = $origStates[$name] -ne $enabled
                $suffix = if ($changed) { ' *' } else { '' }

                $typeTag = "($type)".PadRight(10)

                if ($i -eq $cursor) {
                    Write-Host "  $marker " -NoNewline -ForegroundColor Yellow
                    Write-Host "$checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$typeTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$name$suffix" -ForegroundColor White
                } else {
                    Write-Host "  $marker $checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$typeTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$name$suffix" -ForegroundColor Gray
                }
                $linesWritten++
            }
            $lastLineCount = $linesWritten

            # Input
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $keys.Count - 1) { $cursor++ } }
                'Spacebar'  {
                    $name = $keys[$cursor]
                    $currentStates[$name] = -not $currentStates[$name]
                }
                'Tab'       {
                    if ($scopes.Count -gt 1) {
                        $scopeIdx = ($scopeIdx + 1) % $scopes.Count
                        $cursor = 0
                    }
                }
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

    # Apply changes
    $globalChanges = @{}
    foreach ($k in $globalStates.Keys) {
        if ($globalOrig[$k] -ne $globalStates[$k]) { $globalChanges[$k] = $globalStates[$k] }
    }
    $localChanges = @{}
    if ($hasLocal) {
        foreach ($k in $localStates.Keys) {
            if ($localOrig[$k] -ne $localStates[$k]) { $localChanges[$k] = $localStates[$k] }
        }
    }

    if ($globalChanges.Count -eq 0 -and $localChanges.Count -eq 0) {
        Write-Host "`n  No changes." -ForegroundColor DarkGray
        return
    }

    if ($globalChanges.Count -gt 0) {
        Write-JsoncPreservingComments -Path $GlobalPath -McpStates $globalChanges
    }
    if ($localChanges.Count -gt 0 -and $LocalPath) {
        Write-JsoncPreservingComments -Path $LocalPath -McpStates $localChanges
    }

    Write-Host ""
    foreach ($k in $globalChanges.Keys) {
        $state = if ($globalChanges[$k]) { 'enabled' } else { 'disabled' }
        $color = if ($globalChanges[$k]) { 'Green' } else { 'Red' }
        Write-Host "  [global] $k -> " -NoNewline; Write-Host $state -ForegroundColor $color
    }
    foreach ($k in $localChanges.Keys) {
        $state = if ($localChanges[$k]) { 'enabled' } else { 'disabled' }
        $color = if ($localChanges[$k]) { 'Green' } else { 'Red' }
        Write-Host "  [local]  $k -> " -NoNewline; Write-Host $state -ForegroundColor $color
    }
    Write-Host ""
}

function Set-OCMcp {
    <#
    .SYNOPSIS
        Toggle MCP servers in your OpenCode config.
    .DESCRIPTION
        Without parameters, shows an interactive menu to browse and toggle MCP servers.
        With -Name, directly toggles the specified server. Use -Scope to target Global or Local config.
    .PARAMETER Name
        Name of the MCP server to toggle.
    .PARAMETER Scope
        Config scope: Global or Local. Defaults to Global.
    .EXAMPLE
        Set-OCMcp
        # Opens interactive menu
    .EXAMPLE
        Set-OCMcp -Name figma
        # Toggles the 'figma' MCP server in global config
    .EXAMPLE
        Set-OCMcp -Name figma -Scope Local
        # Toggles in project-local config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [ValidateSet('Global', 'Local')]
        [string]$Scope = 'Global'
    )

    $paths = Get-ConfigPaths
    $globalPath = $paths.Global
    $localPath  = $paths.Local

    if (-not (Test-Path $globalPath)) {
        Write-Error "Global config not found at $globalPath"
        return
    }

    if ($Name) {
        # Direct toggle
        $targetPath = if ($Scope -eq 'Local' -and $localPath) { $localPath } else { $globalPath }
        $servers = Get-McpServers $targetPath
        if (-not $servers.Contains($Name)) {
            Write-Error "MCP server '$Name' not found in $Scope config ($targetPath)"
            return
        }
        $newState = -not $servers[$Name].Enabled
        Write-JsoncPreservingComments -Path $targetPath -McpStates @{ $Name = $newState }
        $label = if ($newState) { 'enabled' } else { 'disabled' }
        $color = if ($newState) { 'Green' } else { 'Red' }
        Write-Host "  [$($Scope.ToLower())] $Name -> " -NoNewline; Write-Host $label -ForegroundColor $color
    }
    else {
        # Interactive mode
        $globalServers = Get-McpServers $globalPath
        $localServers = [ordered]@{}
        if ($localPath) { $localServers = Get-McpServers $localPath }

        Show-InteractiveMenu -GlobalServers $globalServers -LocalServers $localServers `
                             -GlobalPath $globalPath -LocalPath $localPath
    }
}

New-Alias -Name ocmcp -Value Set-OCMcp -Force

Export-ModuleMember -Function Set-OCMcp -Alias ocmcp
