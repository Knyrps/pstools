Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# WorkProject - toggle dev project stacks
#   Resources: services, IIS app pools/sites, docker containers, commands,
#              processes. Readiness checks (TCP + HTTP). Conflict detection.
# ----------------------------------------------------------------------------

$script:ConfigDir   = Join-Path $env:USERPROFILE '.config\pstools'
$script:ConfigPath  = Join-Path $script:ConfigDir 'workproject.json'
$script:StatePath   = Join-Path $script:ConfigDir 'workproject-state.json'

# ═══════════════════════════════════════════════════════════════════════════════
# Config
# ═══════════════════════════════════════════════════════════════════════════════

function Get-WPConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        Write-Error "Config not found at $script:ConfigPath"
        return $null
    }
    try {
        $raw = Get-Content -Path $script:ConfigPath -Raw -Encoding utf8
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse $($script:ConfigPath): $($_.Exception.Message)"
        return $null
    }
}

function Get-WPProjects {
    $cfg = Get-WPConfig
    if (-not $cfg) { return [ordered]@{} }
    $result = [ordered]@{}
    foreach ($prop in $cfg.projects.PSObject.Properties) {
        $result[$prop.Name] = $prop.Value
    }
    return $result
}

function Test-WPElevated {
    $id  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $pri.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WPAppCmd {
    $p = "$env:WINDIR\System32\inetsrv\appcmd.exe"
    if (Test-Path $p) { return $p }
    return $null
}

# Helper: safe property access for optional arrays
function Get-WPArray {
    param($Object, [string]$Property)
    if (-not $Object) { return ,@() }
    if ($Object.PSObject.Properties.Name -contains $Property) {
        $val = $Object.$Property
        if ($null -eq $val) { return ,@() }
        return ,@($val)
    }
    return ,@()
}

function Test-WPAlwaysOn {
    param([Parameter(Mandatory)] $Project)
    $hasProp = $Project.PSObject.Properties.Name -contains '_alwaysOn'
    return $hasProp -and [bool]$Project._alwaysOn
}

# ═══════════════════════════════════════════════════════════════════════════════
# Service helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Stop-WPService {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [int] $TimeoutSeconds = 10
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ Ok=$false; Message='missing' } }
    if ($svc.Status -eq 'Stopped') { return @{ Ok=$true; Message='already stopped' } }

    try { $svc.Stop() } catch { return @{ Ok=$false; Message="stop call FAILED ($($_.Exception.Message))" } }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { return @{ Ok=$true; Message='stopped' } }
    }

    # Force kill via CIM
    $w = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $w -or -not $w.ProcessId -or $w.ProcessId -eq 0) {
        return @{ Ok=$false; Message="timeout, no PID to kill (state=$($svc.Status))" }
    }
    $killed = @()
    $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($w.ProcessId)" -ErrorAction SilentlyContinue
    foreach ($k in @($kids)) {
        try { Stop-Process -Id $k.ProcessId -Force -ErrorAction Stop; $killed += "child $($k.Name)[$($k.ProcessId)]" } catch {}
    }
    try { Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop; $killed += "wrapper $($w.Name)[$($w.ProcessId)]" } catch {}

    Start-Sleep -Milliseconds 500; $svc.Refresh()
    if ($svc.Status -eq 'Stopped') { return @{ Ok=$true; Message="force-killed: $($killed -join ', ')" } }
    return @{ Ok=$false; Message="still $($svc.Status) after force-kill of $($killed -join ', ')" }
}

function Start-WPService {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [int] $TimeoutSeconds = 90
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ Ok=$false; Message='missing' } }
    if ($svc.Status -eq 'Running') { return @{ Ok=$true; Message='already running' } }

    try { $svc.Start() } catch { return @{ Ok=$false; Message="start call FAILED ($($_.Exception.Message))" } }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $svc.Refresh()
        if ($svc.Status -eq 'Running') { return @{ Ok=$true; Message='started' } }
        if ($svc.Status -eq 'Stopped') { return @{ Ok=$false; Message='exited immediately (check Event Viewer)' } }
    }
    return @{ Ok=$false; Message="timeout after ${TimeoutSeconds}s (state=$($svc.Status); may still come up)" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Docker helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Test-WPDockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    return $true
}

function Get-WPDockerDaemonOs {
    try { return (docker version -f '{{.Server.Os}}' 2>$null) } catch { return $null }
}

function Get-WPContainerState {
    param([string]$ContainerName)
    $running = docker ps --filter "name=^${ContainerName}$" --format '{{.Names}}' 2>$null
    if ($running -eq $ContainerName) { return 'running' }
    $any = docker ps -a --filter "name=^${ContainerName}$" --format '{{.Names}}' 2>$null
    if ($any -eq $ContainerName) { return 'stopped' }
    return 'missing'
}

function Start-WPContainer {
    param([Parameter(Mandatory)] $Spec)
    $name = $Spec.name
    $state = Get-WPContainerState $name

    if ($state -eq 'running') {
        Write-Host "  docker $name : already running" -ForegroundColor DarkGray
        return
    }
    if ($state -eq 'stopped') {
        Write-Host "  docker $name : removing stopped container..." -ForegroundColor DarkGray
        docker rm $name 2>$null | Out-Null
    }

    $args = @('run', '-d', '--name', $name)

    # --rm unless explicitly disabled
    $useRm = $true
    if ($Spec.PSObject.Properties.Name -contains 'rm') { $useRm = [bool]$Spec.rm }
    if ($useRm) { $args += '--rm' }

    # Port mappings
    foreach ($port in (Get-WPArray $Spec 'ports')) { $args += '-p'; $args += $port }

    # Environment variables
    foreach ($env in (Get-WPArray $Spec 'env')) { $args += '-e'; $args += $env }

    # Volumes
    foreach ($vol in (Get-WPArray $Spec 'volumes')) { $args += '-v'; $args += $vol }

    # Extra args
    foreach ($extra in (Get-WPArray $Spec 'args')) { $args += $extra }

    $args += $Spec.image

    # Command override
    foreach ($cmd in (Get-WPArray $Spec 'command')) { $args += $cmd }

    $id = & docker @args 2>&1
    if ($LASTEXITCODE -eq 0) {
        $short = if ($id.Length -gt 12) { $id.Substring(0, 12) } else { $id }
        Write-Host "  docker $name : started ($short)" -ForegroundColor Green
    } else {
        Write-Host "  docker $name : FAILED ($id)" -ForegroundColor Red
    }
}

function Stop-WPContainer {
    param([Parameter(Mandatory)] $Spec)
    $name = $Spec.name
    $state = Get-WPContainerState $name
    if ($state -eq 'missing') {
        Write-Host "  docker $name : not running" -ForegroundColor DarkGray
        return
    }
    docker stop $name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  docker $name : stopped" -ForegroundColor Yellow
    } else {
        Write-Host "  docker $name : stop FAILED" -ForegroundColor Red
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Generic commands
# ═══════════════════════════════════════════════════════════════════════════════

function Start-WPCommand {
    <#
    .SYNOPSIS Launch a background command defined in the project config.
    Config shape: { "name": "vite", "start": "npm run dev", "cwd": "D:\\...", "stop": "kill" }
    Stop strategies: "kill" (default) = kill by PID file; "command" = run the stop field as a command.
    #>
    param([Parameter(Mandatory)] $Spec)
    $name = $Spec.name
    $pidDir = Join-Path $script:ConfigDir 'pids'
    if (-not (Test-Path $pidDir)) { New-Item -ItemType Directory -Path $pidDir -Force | Out-Null }
    $pidFile = Join-Path $pidDir "$name.pid"

    # Check if already running
    if (Test-Path $pidFile) {
        $existingPid = Get-Content $pidFile -Raw -ErrorAction SilentlyContinue
        if ($existingPid) {
            $existingPid = $existingPid.Trim()
            $proc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "  cmd $name : already running (PID $existingPid)" -ForegroundColor DarkGray
                return
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    $startCmd = $Spec.start
    $cwd = if ($Spec.PSObject.Properties.Name -contains 'cwd') { $Spec.cwd } else { (Get-Location).Path }

    # Build environment if specified
    $envVars = @{}
    foreach ($e in (Get-WPArray $Spec 'env')) {
        $parts = $e -split '=', 2
        if ($parts.Count -eq 2) { $envVars[$parts[0]] = $parts[1] }
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c $startCmd"
        $psi.WorkingDirectory = $cwd
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false

        foreach ($k in $envVars.Keys) {
            $psi.EnvironmentVariables[$k] = $envVars[$k]
        }

        $p = [System.Diagnostics.Process]::Start($psi)
        Set-Content -Path $pidFile -Value $p.Id -Encoding utf8
        Write-Host "  cmd $name : started (PID $($p.Id))" -ForegroundColor Green
    } catch {
        Write-Host "  cmd $name : FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Stop-WPCommand {
    param([Parameter(Mandatory)] $Spec)
    $name = $Spec.name
    $pidFile = Join-Path $script:ConfigDir "pids\$name.pid"
    $stopStrategy = if ($Spec.PSObject.Properties.Name -contains 'stop') { $Spec.stop } else { 'kill' }

    if ($stopStrategy -ne 'kill' -and $stopStrategy -ne 'command') {
        # Treat the stop field as a command to run
        $stopStrategy = 'command'
    }

    if ($stopStrategy -eq 'kill' -or $Spec.stop -eq 'kill') {
        if (-not (Test-Path $pidFile)) {
            Write-Host "  cmd $name : no PID file (not running?)" -ForegroundColor DarkGray
            return
        }
        $pid = (Get-Content $pidFile -Raw).Trim()
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            # Kill children first
            $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$pid" -ErrorAction SilentlyContinue
            foreach ($k in @($kids)) {
                try { Stop-Process -Id $k.ProcessId -Force -ErrorAction Stop } catch {}
            }
            try { Stop-Process -Id $pid -Force -ErrorAction Stop } catch {}
            Write-Host "  cmd $name : killed (PID $pid)" -ForegroundColor Yellow
        } else {
            Write-Host "  cmd $name : PID $pid already gone" -ForegroundColor DarkGray
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } else {
        # Run the stop command
        $cwd = if ($Spec.PSObject.Properties.Name -contains 'cwd') { $Spec.cwd } else { (Get-Location).Path }
        $stopCmd = $Spec.stop
        try {
            $result = cmd /c $stopCmd 2>&1
            Write-Host "  cmd $name : stop command executed" -ForegroundColor Yellow
        } catch {
            Write-Host "  cmd $name : stop FAILED ($($_.Exception.Message))" -ForegroundColor Red
        }
        if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
    }
}

function Get-WPCommandState {
    param([Parameter(Mandatory)] $Spec)
    $pidFile = Join-Path $script:ConfigDir "pids\$($Spec.name).pid"
    if (-not (Test-Path $pidFile)) { return 'Stopped' }
    $pid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if (-not $pid) { return 'Stopped' }
    $proc = Get-Process -Id $pid.Trim() -ErrorAction SilentlyContinue
    if ($proc) { return 'Running' }
    # Stale PID file
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    return 'Stopped'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Readiness checks (TCP + HTTP) - replaces warmupUrls
# ═══════════════════════════════════════════════════════════════════════════════

function Test-WPTcpPort {
    param([string]$Host_, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($Host_, $Port)
        $completed = $task.Wait($TimeoutMs)
        $connected = $completed -and $client.Connected
        try { $client.Close() } catch {}
        return $connected
    } catch {
        return $false
    }
}

function Invoke-WPReadinessChecks {
    <#
    .SYNOPSIS Run readiness checks defined in the project config.
    Supports: { "type": "tcp", "host": "localhost", "port": 8983, "label": "Solr" }
              { "type": "http", "url": "https://cm.local", "label": "CM" }
    Also supports legacy warmupUrls array (treated as http checks).
    #>
    param(
        [Parameter(Mandatory)] $Project,
        [int] $TimeoutSeconds = 60
    )

    $checks = @()

    # New-style readiness array
    foreach ($r in (Get-WPArray $Project 'readiness')) { $checks += $r }

    # Legacy warmupUrls -> http checks
    foreach ($u in (Get-WPArray $Project 'warmupUrls')) {
        $checks += [PSCustomObject]@{ type='http'; url=$u; label=$u }
    }

    if ($checks.Count -eq 0) { return }

    $hasSkipCert = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')

    foreach ($check in $checks) {
        $label = if ($check.PSObject.Properties.Name -contains 'label') { $check.label } else { "$($check.type)" }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $ok = $false

        switch ($check.type) {
            'tcp' {
                $host_ = if ($check.PSObject.Properties.Name -contains 'host') { $check.host } else { 'localhost' }
                $port = $check.port
                while ((Get-Date) -lt $deadline) {
                    if (Test-WPTcpPort -Host_ $host_ -Port $port -TimeoutMs 2000) { $ok = $true; break }
                    Start-Sleep -Milliseconds 750
                }
                if ($ok) { Write-Host "  ready $label : tcp ${host_}:$port OK" -ForegroundColor Green }
                else     { Write-Host "  ready $label : tcp ${host_}:$port TIMEOUT" -ForegroundColor DarkYellow }
            }
            'http' {
                $url = $check.url
                $lastInfo = ''
                while ((Get-Date) -lt $deadline) {
                    $code = $null
                    try {
                        $iwrArgs = @{
                            Uri = $url; TimeoutSec = 5; MaximumRedirection = 0
                            UseBasicParsing = $true; ErrorAction = 'Stop'
                        }
                        if ($hasSkipCert) { $iwrArgs.SkipCertificateCheck = $true }
                        $resp = Invoke-WebRequest @iwrArgs
                        $code = [int]$resp.StatusCode
                    } catch {
                        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                        if (-not $code) { $lastInfo = $_.Exception.Message }
                    }
                    if ($code) { $ok = $true; $lastInfo = "$code"; break }
                    Start-Sleep -Milliseconds 750
                }
                if ($ok) { Write-Host "  ready $label : http $lastInfo" -ForegroundColor Green }
                else     { Write-Host "  ready $label : http TIMEOUT ($lastInfo)" -ForegroundColor DarkYellow }
            }
            default {
                Write-Host "  ready $label : unknown check type '$($check.type)'" -ForegroundColor Red
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Conflict detection
# ═══════════════════════════════════════════════════════════════════════════════

function Test-WPConflicts {
    <#
    .SYNOPSIS Check for conflicts before enabling a project.
    Reads optional _requires block from the project config:
      "_requires": { "dockerDaemon": "linux", "node": ">=22" }
    Returns array of conflict messages (empty = no conflicts).
    #>
    param([Parameter(Mandatory)] $Project, [string]$ProjectName)

    $conflicts = @()
    $req = $null
    if ($Project.PSObject.Properties.Name -contains '_requires') { $req = $Project._requires }
    if (-not $req) { return $conflicts }

    # Docker daemon mode check
    if ($req.PSObject.Properties.Name -contains 'dockerDaemon') {
        $needed = $req.dockerDaemon   # 'linux' or 'windows'
        if (Test-WPDockerAvailable) {
            $current = Get-WPDockerDaemonOs
            if ($current -and $current -ne $needed) {
                $conflicts += "[$ProjectName] requires Docker in '$needed' mode, currently '$current'. Switch with 'dockersw'."
            }
        } else {
            $conflicts += "[$ProjectName] requires Docker ($needed daemon) but docker CLI not found."
        }
    }

    # Node version check
    if ($req.PSObject.Properties.Name -contains 'node') {
        $constraint = $req.node  # e.g. ">=22", "<25", "22"
        $nodeVer = $null
        try { $nodeVer = (node --version 2>$null) -replace '^v', '' } catch {}
        if ($nodeVer) {
            $major = [int]($nodeVer -split '\.')[0]
            $ok = $true
            if ($constraint -match '^>=(\d+)$') { $ok = $major -ge [int]$Matches[1] }
            elseif ($constraint -match '^<=(\d+)$') { $ok = $major -le [int]$Matches[1] }
            elseif ($constraint -match '^<(\d+)$') { $ok = $major -lt [int]$Matches[1] }
            elseif ($constraint -match '^>(\d+)$') { $ok = $major -gt [int]$Matches[1] }
            elseif ($constraint -match '^\d+$') { $ok = $major -eq [int]$constraint }
            if (-not $ok) {
                $conflicts += "[$ProjectName] requires node $constraint, current is v$nodeVer."
            }
        }
    }

    return $conflicts
}

# ═══════════════════════════════════════════════════════════════════════════════
# Project state
# ═══════════════════════════════════════════════════════════════════════════════

function Get-WPProjectState {
    param([Parameter(Mandatory)] $Project)

    $svcStates  = @()
    foreach ($s in (Get-WPArray $Project 'services')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { $svcStates += [PSCustomObject]@{ Name=$s; Status=$svc.Status; Exists=$true } }
        else      { $svcStates += [PSCustomObject]@{ Name=$s; Status='Missing'; Exists=$false } }
    }

    $poolStates = @()
    $appcmd = Get-WPAppCmd
    $pools = Get-WPArray $Project 'iisAppPools'
    if ($appcmd -and $pools.Count -gt 0) {
        $raw = & $appcmd list apppool 2>$null
        foreach ($pool in $pools) {
            $line = $raw | Where-Object { $_ -match "APPPOOL `"$([regex]::Escape($pool))`"" } | Select-Object -First 1
            if ($line) {
                $state = if ($line -match 'state:(\w+)') { $matches[1] } else { '?' }
                $poolStates += [PSCustomObject]@{ Name=$pool; Status=$state; Exists=$true }
            } else {
                $poolStates += [PSCustomObject]@{ Name=$pool; Status='Missing'; Exists=$false }
            }
        }
    }

    $siteStates = @()
    $sites = Get-WPArray $Project 'iisSites'
    if ($appcmd -and $sites.Count -gt 0) {
        $raw = & $appcmd list site 2>$null
        foreach ($site in $sites) {
            $line = $raw | Where-Object { $_ -match "SITE `"$([regex]::Escape($site))`"" } | Select-Object -First 1
            if ($line) {
                $state = if ($line -match 'state:(\w+)') { $matches[1] } else { '?' }
                $siteStates += [PSCustomObject]@{ Name=$site; Status=$state; Exists=$true }
            } else {
                $siteStates += [PSCustomObject]@{ Name=$site; Status='Missing'; Exists=$false }
            }
        }
    }

    $dockerStates = @()
    $containers = Get-WPArray $Project 'docker'
    if ($containers.Count -gt 0 -and (Test-WPDockerAvailable)) {
        foreach ($c in $containers) {
            $s = Get-WPContainerState $c.name
            $dockerStates += [PSCustomObject]@{ Name=$c.name; Status=$s; Exists=($s -ne 'missing' -or $true) }
        }
    }

    $cmdStates = @()
    foreach ($c in (Get-WPArray $Project 'commands')) {
        $s = Get-WPCommandState $c
        $cmdStates += [PSCustomObject]@{ Name=$c.name; Status=$s }
    }

    $procStates = @()
    foreach ($p in (Get-WPArray $Project 'processes')) {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='$($p.name).exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match $p.cmdLineMatch) })
        $procStates += [PSCustomObject]@{
            Name = $p.name; Match = $p.cmdLineMatch
            Status = if ($running.Count -gt 0) { "Running ($($running.Count))" } else { 'Stopped' }
            Pids = @($running.ProcessId)
        }
    }

    # Aggregate
    $allOn = $true; $anyOn = $false
    foreach ($s in $svcStates)    { if ($s.Exists) { if ($s.Status -ne 'Running') { $allOn = $false } else { $anyOn = $true } } }
    foreach ($s in $poolStates)   { if ($s.Exists) { if ($s.Status -ne 'Started') { $allOn = $false } else { $anyOn = $true } } }
    foreach ($s in $siteStates)   { if ($s.Exists) { if ($s.Status -ne 'Started') { $allOn = $false } else { $anyOn = $true } } }
    foreach ($s in $dockerStates) { if ($s.Status -ne 'running') { $allOn = $false } else { $anyOn = $true } }
    foreach ($s in $cmdStates)    { if ($s.Status -ne 'Running') { $allOn = $false } else { $anyOn = $true } }

    $hasItems = ($svcStates.Count + $poolStates.Count + $siteStates.Count + $dockerStates.Count + $cmdStates.Count) -gt 0
    $aggregate = if (-not $hasItems) { 'Empty' }
                 elseif ($allOn -and $anyOn) { 'Enabled' }
                 elseif ($anyOn) { 'Partial' }
                 else { 'Disabled' }

    return [PSCustomObject]@{
        Services   = $svcStates
        AppPools   = $poolStates
        Sites      = $siteStates
        Docker     = $dockerStates
        Commands   = $cmdStates
        Processes  = $procStates
        Aggregate  = $aggregate
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Apply enable/disable
# ═══════════════════════════════════════════════════════════════════════════════

function _WP-ApplyServices {
    param($Project, [string]$Action)
    foreach ($s in (Get-WPArray $Project 'services')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Host "  service $s : MISSING" -ForegroundColor DarkYellow; continue }
        if ($Action -eq 'Enable') {
            try {
                if ($svc.StartType -ne 'Automatic') { Set-Service -Name $s -StartupType Automatic -ErrorAction Stop }
            } catch { Write-Host "  service $s : StartType FAILED ($($_.Exception.Message))" -ForegroundColor Red }
            if ($svc.Status -eq 'Running') { Write-Host "  service $s : already running (auto)" -ForegroundColor DarkGray }
            else {
                $r = Start-WPService -Name $s -TimeoutSeconds 90
                if ($r.Ok) { Write-Host "  service $s : $($r.Message) + auto" -ForegroundColor Green }
                else       { Write-Host "  service $s : FAILED ($($r.Message))" -ForegroundColor Red }
            }
        } else {
            try {
                if ($svc.StartType -eq 'Automatic') { Set-Service -Name $s -StartupType Manual -ErrorAction Stop }
            } catch { Write-Host "  service $s : StartType FAILED ($($_.Exception.Message))" -ForegroundColor Red }
            if ($svc.Status -eq 'Stopped') { Write-Host "  service $s : already stopped (manual)" -ForegroundColor DarkGray }
            else {
                $r = Stop-WPService -Name $s -TimeoutSeconds 10
                if ($r.Ok) { Write-Host "  service $s : $($r.Message) + manual" -ForegroundColor Yellow }
                else       { Write-Host "  service $s : FAILED ($($r.Message))" -ForegroundColor Red }
            }
        }
    }
}

function _WP-ApplyIIS {
    param($Project, [string]$Action)
    $appcmd = Get-WPAppCmd
    $pools = Get-WPArray $Project 'iisAppPools'
    $sites = Get-WPArray $Project 'iisSites'
    if (-not $appcmd) {
        if ($pools.Count -gt 0 -or $sites.Count -gt 0) {
            Write-Host "  appcmd.exe not found; cannot manage IIS." -ForegroundColor Red
        }
        return
    }
    $cmd = if ($Action -eq 'Enable') { 'start' } else { 'stop' }
    $col = if ($Action -eq 'Enable') { 'Green' } else { 'Yellow' }
    if ($Action -eq 'Enable') {
        foreach ($pool in $pools) {
            $out = & $appcmd $cmd apppool $pool 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host "  apppool $pool : $cmd" -ForegroundColor $col }
            else { Write-Host "  apppool $pool : $out" -ForegroundColor DarkGray }
        }
        foreach ($site in $sites) {
            $out = & $appcmd $cmd site $site 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host "  site $site : $cmd" -ForegroundColor $col }
            else { Write-Host "  site $site : $out" -ForegroundColor DarkGray }
        }
    } else {
        foreach ($site in $sites) {
            $out = & $appcmd $cmd site $site 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host "  site $site : $cmd" -ForegroundColor $col }
            else { Write-Host "  site $site : $out" -ForegroundColor DarkGray }
        }
        foreach ($pool in $pools) {
            $out = & $appcmd $cmd apppool $pool 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host "  apppool $pool : $cmd" -ForegroundColor $col }
            else { Write-Host "  apppool $pool : $out" -ForegroundColor DarkGray }
        }
    }
}

function _WP-ApplyDocker {
    param($Project, [string]$Action)
    $containers = Get-WPArray $Project 'docker'
    if ($containers.Count -eq 0) { return }
    if (-not (Test-WPDockerAvailable)) {
        Write-Host "  docker CLI not found; cannot manage containers." -ForegroundColor Red
        return
    }
    foreach ($c in $containers) {
        if ($Action -eq 'Enable') { Start-WPContainer $c }
        else { Stop-WPContainer $c }
    }
}

function _WP-ApplyCommands {
    param($Project, [string]$Action)
    foreach ($c in (Get-WPArray $Project 'commands')) {
        if ($Action -eq 'Enable') { Start-WPCommand $c }
        else { Stop-WPCommand $c }
    }
}

function _WP-KillProcesses {
    param($Project)
    foreach ($proc in (Get-WPArray $Project 'processes')) {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='$($proc.name).exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match $proc.cmdLineMatch) })
        foreach ($r in $running) {
            try { Stop-Process -Id $r.ProcessId -Force -ErrorAction Stop; Write-Host "  proc $($proc.name) [$($r.ProcessId)] : killed" -ForegroundColor Yellow }
            catch { Write-Host "  proc $($proc.name) [$($r.ProcessId)] : FAILED" -ForegroundColor Red }
        }
    }
}

function Set-WPProjectState {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Enable','Disable')] [string] $Action,
        [switch] $Force,
        [switch] $SkipReadiness
    )

    if (-not (Test-WPElevated)) {
        Write-Warning "Not elevated. Service/IIS changes will likely fail. Re-run from an admin PowerShell."
    }

    $projects = Get-WPProjects
    if (-not $projects.Contains($Name)) {
        Write-Error "Unknown project '$Name'. Run Get-WorkProject to see available."
        return
    }
    $p = $projects[$Name]

    if ($Action -eq 'Disable' -and (Test-WPAlwaysOn $p) -and -not $Force) {
        Write-Host "[$Name] " -NoNewline -ForegroundColor Cyan
        Write-Host "always-on; refusing to disable (use -Force to override)" -ForegroundColor DarkYellow
        return
    }

    # Conflict check on enable
    if ($Action -eq 'Enable') {
        $conflicts = Test-WPConflicts -Project $p -ProjectName $Name
        if ($conflicts.Count -gt 0) {
            foreach ($c in $conflicts) { Write-Warning $c }
            if (-not $Force) {
                Write-Host "  Use -Force to enable anyway." -ForegroundColor DarkYellow
                return
            }
        }
    }

    $color = if ($Action -eq 'Enable') { 'Green' } else { 'Red' }
    Write-Host "[$Name] " -NoNewline -ForegroundColor Cyan
    Write-Host "$Action" -ForegroundColor $color

    if ($Action -eq 'Enable') {
        # Order: Docker -> IIS -> readiness -> services -> commands
        _WP-ApplyDocker   -Project $p -Action Enable
        _WP-ApplyIIS      -Project $p -Action Enable
        if (-not $SkipReadiness) { Invoke-WPReadinessChecks -Project $p -TimeoutSeconds 60 }
        _WP-ApplyServices -Project $p -Action Enable
        _WP-ApplyCommands -Project $p -Action Enable
    } else {
        # Reverse: commands -> services -> IIS -> Docker -> processes
        _WP-ApplyCommands -Project $p -Action Disable
        _WP-ApplyServices -Project $p -Action Disable
        _WP-ApplyIIS      -Project $p -Action Disable
        _WP-ApplyDocker   -Project $p -Action Disable
        _WP-KillProcesses -Project $p
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Suspend / Resume
# ═══════════════════════════════════════════════════════════════════════════════

function Suspend-WorkProject {
    <#
    .SYNOPSIS Remember currently-enabled projects, then disable them all.
    #>
    $projects = Get-WPProjects
    $enabled = @()
    foreach ($n in $projects.Keys) {
        if (Test-WPAlwaysOn $projects[$n]) { continue }
        $state = Get-WPProjectState -Project $projects[$n]
        if ($state.Aggregate -in 'Enabled','Partial') { $enabled += $n }
    }
    @{ EnabledAt = (Get-Date).ToString('o'); Projects = $enabled } | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding utf8
    Write-Host "Saved state ($($enabled.Count) projects enabled): $($enabled -join ', ')" -ForegroundColor Cyan
    foreach ($n in $enabled) { Set-WPProjectState -Name $n -Action Disable }
}

function Resume-WorkProject {
    <#
    .SYNOPSIS Re-enable projects that were enabled when Suspend-WorkProject ran.
    #>
    if (-not (Test-Path $script:StatePath)) {
        Write-Error "No saved state at $($script:StatePath). Run Suspend-WorkProject first."
        return
    }
    $state = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
    Write-Host "Restoring $($state.Projects.Count) projects (saved $($state.EnabledAt))" -ForegroundColor Cyan
    foreach ($n in $state.Projects) { Set-WPProjectState -Name $n -Action Enable }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-WorkspaceCleanup {
    <#
    .SYNOPSIS Kill zombie conhost/cmd, dedupe Spotify, clear old %TEMP%.
    #>
    [CmdletBinding()]
    param(
        [switch] $SkipTemp,
        [switch] $WhatIf
    )

    Write-Host "=== Workspace Cleanup ===" -ForegroundColor Cyan

    $myPid = $PID
    $protected = @($myPid)
    $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$myPid" -ErrorAction SilentlyContinue
    while ($cur -and $cur.ParentProcessId) {
        $protected += $cur.ParentProcessId
        $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
    }

    $killed = 0
    foreach ($name in @('conhost','cmd')) {
        $procs = Get-CimInstance Win32_Process -Filter "Name='$name.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($protected -contains $p.ProcessId) { continue }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
            $shouldKill = $false
            if ($name -eq 'conhost') {
                if (-not $parent) { $shouldKill = $true }
                elseif ($parent.Name -notmatch '^(pwsh|powershell|cmd|wt|WindowsTerminal|opencode|claude|Code)\.exe$') { $shouldKill = $true }
            } else {
                $ps = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                if ($ps -and $ps.MainWindowHandle -eq 0) { $shouldKill = $true }
            }
            if ($shouldKill) {
                if ($WhatIf) { Write-Host "  WOULD KILL $name [$($p.ProcessId)] parent=$($p.ParentProcessId)" -ForegroundColor DarkGray }
                else { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch { } }
            }
        }
    }
    Write-Host "  Zombie shells killed: $killed" -ForegroundColor Green

    $spot = Get-Process Spotify -ErrorAction SilentlyContinue | Sort-Object StartTime
    if ($spot.Count -gt 1) {
        $extras = $spot | Select-Object -Skip 1
        $freed = ($extras | Measure-Object WorkingSet64 -Sum).Sum / 1MB
        foreach ($e in $extras) {
            if ($WhatIf) { Write-Host "  WOULD KILL Spotify [$($e.Id)]" -ForegroundColor DarkGray }
            else { try { Stop-Process -Id $e.Id -Force -ErrorAction Stop } catch {} }
        }
        Write-Host "  Spotify extras killed: $($extras.Count) (~$([math]::Round($freed,0)) MB freed)" -ForegroundColor Green
    } else {
        Write-Host "  Spotify: no duplicates" -ForegroundColor DarkGray
    }

    if (-not $SkipTemp) {
        $cutoff = (Get-Date).AddDays(-7)
        $temps = @($env:TEMP, "$env:WINDIR\Temp") | Sort-Object -Unique
        $totalFreed = 0; $totalFiles = 0
        foreach ($t in $temps) {
            if (-not (Test-Path $t)) { continue }
            $old = Get-ChildItem -LiteralPath $t -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -lt $cutoff }
            foreach ($f in $old) {
                $sz = $f.Length
                if ($WhatIf) { $totalFreed += $sz; $totalFiles++; continue }
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $totalFreed += $sz; $totalFiles++ } catch {}
            }
        }
        $mb = [math]::Round($totalFreed / 1MB, 1)
        Write-Host "  Temp files >7d deleted: $totalFiles ($mb MB)" -ForegroundColor Green
    }

    Write-Host "Done." -ForegroundColor Cyan
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-WorkProject
# ═══════════════════════════════════════════════════════════════════════════════

function Get-WorkProject {
    <#
    .SYNOPSIS List configured projects and their current state.
    #>
    [CmdletBinding()]
    param([string] $Name)

    $projects = Get-WPProjects
    if (-not $projects -or $projects.Count -eq 0) { Write-Warning "No projects configured."; return }

    $rows = foreach ($n in $projects.Keys) {
        if ($Name -and $n -ne $Name) { continue }
        $p = $projects[$n]
        $state = Get-WPProjectState -Project $p
        [PSCustomObject]@{
            Project     = $n
            State       = $state.Aggregate
            Services    = (Get-WPArray $p 'services').Count
            AppPools    = (Get-WPArray $p 'iisAppPools').Count
            Sites       = (Get-WPArray $p 'iisSites').Count
            Docker      = (Get-WPArray $p 'docker').Count
            Commands    = (Get-WPArray $p 'commands').Count
            Procs       = (Get-WPArray $p 'processes').Count
            Description = $p.description
        }
    }
    $rows | Format-Table -AutoSize
}

# ═══════════════════════════════════════════════════════════════════════════════
# Interactive menu
# ═══════════════════════════════════════════════════════════════════════════════

function Show-WPMenu {
    $projects = Get-WPProjects
    if (-not $projects -or $projects.Count -eq 0) { Write-Warning "No projects configured."; return }
    $keys = @($projects.Keys)

    $state = [ordered]@{}
    $locked = [ordered]@{}
    foreach ($n in $keys) {
        $s = Get-WPProjectState -Project $projects[$n]
        $state[$n] = $s.Aggregate
        $locked[$n] = (Test-WPAlwaysOn $projects[$n])
    }
    $desired = [ordered]@{}
    foreach ($n in $keys) {
        if ($locked[$n]) { $desired[$n] = $true }
        else { $desired[$n] = ($state[$n] -eq 'Enabled' -or $state[$n] -eq 'Partial') }
    }
    $orig = [ordered]@{}; foreach ($n in $keys) { $orig[$n] = $desired[$n] }

    $cursor = 0; $done = $false; $cancelled = $false

    [Console]::CursorVisible = $false
    try {
        while (-not $done) {
            [Console]::Clear()
            Write-Host "  WorkProject  |  Toggle dev project stacks" -ForegroundColor Cyan
            Write-Host "  [Space] toggle  [Enter] apply  [Esc] cancel  [A] all  [N] none  [S] suspend  [R] resume  [C] cleanup" -ForegroundColor DarkGray
            Write-Host ""

            for ($i=0; $i -lt $keys.Count; $i++) {
                $n = $keys[$i]
                $isLocked = $locked[$n]
                $marker = if ($i -eq $cursor) { '>' } else { ' ' }
                $checked = $desired[$n]
                $checkbox = if ($isLocked) { '[#]' } elseif ($checked) { '[x]' } else { '[ ]' }
                $color = if ($isLocked) { 'DarkCyan' } elseif ($checked) { 'Green' } else { 'DarkGray' }
                $cur = $state[$n]
                $stateTag = "($cur)".PadRight(11)
                $changed = (-not $isLocked) -and ($orig[$n] -ne $desired[$n])
                $suffix = if ($isLocked) { ' [always-on]' } elseif ($changed) { ' *' } else { '' }
                $p = $projects[$n]
                $desc = if ($p.description) { "  $($p.description)" } else { '' }

                # Resource summary
                $counts = @()
                $svcN = (Get-WPArray $p 'services').Count
                $poolN = (Get-WPArray $p 'iisAppPools').Count
                $siteN = (Get-WPArray $p 'iisSites').Count
                $dockN = (Get-WPArray $p 'docker').Count
                $cmdN = (Get-WPArray $p 'commands').Count
                if ($svcN)  { $counts += "${svcN}svc" }
                if ($poolN) { $counts += "${poolN}pool" }
                if ($siteN) { $counts += "${siteN}site" }
                if ($dockN) { $counts += "${dockN}dock" }
                if ($cmdN)  { $counts += "${cmdN}cmd" }
                $countStr = if ($counts.Count -gt 0) { " ($($counts -join ','))" } else { '' }

                if ($i -eq $cursor) {
                    Write-Host "  $marker " -NoNewline -ForegroundColor Yellow
                    Write-Host "$checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$stateTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$n$suffix" -NoNewline -ForegroundColor White
                    Write-Host "$countStr" -NoNewline -ForegroundColor DarkGray
                    Write-Host $desc -ForegroundColor DarkGray
                } else {
                    Write-Host "  $marker $checkbox " -NoNewline -ForegroundColor $color
                    Write-Host "$stateTag " -NoNewline -ForegroundColor DarkCyan
                    Write-Host "$n$suffix" -NoNewline -ForegroundColor Gray
                    Write-Host "$countStr" -NoNewline -ForegroundColor DarkGray
                    Write-Host $desc -ForegroundColor DarkGray
                }
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $keys.Count-1) { $cursor++ } }
                'Spacebar'  { $n = $keys[$cursor]; if (-not $locked[$n]) { $desired[$n] = -not $desired[$n] } }
                'Enter'     { $done = $true }
                'Escape'    { $done = $true; $cancelled = $true }
                'A'         { foreach ($k in $keys) { $desired[$k] = $true } }
                'N'         { foreach ($k in $keys) { if (-not $locked[$k]) { $desired[$k] = $false } } }
                'S'         { $done = $true; [Console]::Clear(); Suspend-WorkProject; return }
                'R'         { $done = $true; [Console]::Clear(); Resume-WorkProject; return }
                'C'         { $done = $true; [Console]::Clear(); Invoke-WorkspaceCleanup; return }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }

    if ($cancelled) { Write-Host "`n  Cancelled." -ForegroundColor DarkGray; return }

    $changes = @()
    foreach ($n in $keys) {
        if ($orig[$n] -ne $desired[$n]) {
            $changes += [PSCustomObject]@{ Name=$n; Action=$(if ($desired[$n]) { 'Enable' } else { 'Disable' }) }
        }
    }
    if ($changes.Count -eq 0) { Write-Host "`n  No changes." -ForegroundColor DarkGray; return }

    Write-Host ""
    foreach ($c in $changes) { Set-WPProjectState -Name $c.Name -Action $c.Action }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Set-WorkProject (main entry)
# ═══════════════════════════════════════════════════════════════════════════════

function Set-WorkProject {
    <#
    .SYNOPSIS
        Toggle dev project stacks (services, IIS, Docker, commands, processes).
    .DESCRIPTION
        Without parameters, shows an interactive checkbox menu.
        With -Name x, toggles project x. With -Action Enable|Disable, explicit.
        With -Only x, disables every other project and enables x.

        Config at ~/.config/pstools/workproject.json supports resource types:
          services     - Windows services (start/stop + startup type)
          iisAppPools  - IIS application pools
          iisSites     - IIS web sites
          docker       - Docker containers (image, ports, env, volumes)
          commands     - Generic background commands (start/stop/cwd/env)
          processes    - Processes to kill on disable (name + cmdLineMatch)
          readiness    - TCP port or HTTP URL checks before proceeding

        Conflict detection via optional _requires block:
          { "_requires": { "dockerDaemon": "linux", "node": ">=22" } }
    .PARAMETER Name
        Project name (see Get-WorkProject).
    .PARAMETER Action
        Enable, Disable, or Toggle (default = Toggle when -Name is given).
    .PARAMETER Only
        Project name. Disables every other project, enables this one.
    .EXAMPLE
        wp
    .EXAMPLE
        wp myproject
    .EXAMPLE
        wp -Only webapp
    #>
    [CmdletBinding(DefaultParameterSetName='Interactive')]
    param(
        [Parameter(Position=0, ParameterSetName='ByName')]
        [string] $Name,

        [Parameter(ParameterSetName='ByName')]
        [ValidateSet('Enable','Disable','Toggle')]
        [string] $Action = 'Toggle',

        [Parameter(Mandatory, ParameterSetName='Only')]
        [string] $Only
    )

    switch ($PSCmdlet.ParameterSetName) {
        'Interactive' { Show-WPMenu }
        'ByName'      {
            $projects = Get-WPProjects
            if (-not $projects.Contains($Name)) { Write-Error "Unknown project '$Name'."; return }
            if ($Action -eq 'Toggle') {
                $s = Get-WPProjectState -Project $projects[$Name]
                $Action = if ($s.Aggregate -in 'Enabled','Partial') { 'Disable' } else { 'Enable' }
            }
            Set-WPProjectState -Name $Name -Action $Action
        }
        'Only'        {
            $projects = Get-WPProjects
            if (-not $projects.Contains($Only)) { Write-Error "Unknown project '$Only'."; return }
            foreach ($n in $projects.Keys) {
                if ($n -eq $Only) { continue }
                if (Test-WPAlwaysOn $projects[$n]) {
                    Set-WPProjectState -Name $n -Action Enable
                    continue
                }
                Set-WPProjectState -Name $n -Action Disable
            }
            Set-WPProjectState -Name $Only -Action Enable
        }
    }
}

New-Alias -Name wp -Value Set-WorkProject -Force
New-Alias -Name wp-cleanup -Value Invoke-WorkspaceCleanup -Force

Export-ModuleMember -Function Set-WorkProject, Get-WorkProject, Suspend-WorkProject, Resume-WorkProject, Invoke-WorkspaceCleanup -Alias wp, wp-cleanup
