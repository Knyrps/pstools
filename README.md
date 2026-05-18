# PsTools

PowerShell modules for dev environment management. Installable via the `PsTools` module with multi-source support (GitHub repos + local folders).

All config lives under `~/.config/pstools/`.

## Quick Start

**One-liner** (run as Administrator):

```powershell
irm https://raw.githubusercontent.com/Knyrps/pstools/main/install.ps1 | iex
```

**Manual install** (if you don't pipe scripts from the internet):

```powershell
# 1. Download and inspect the installer
Invoke-WebRequest https://raw.githubusercontent.com/Knyrps/pstools/main/install.ps1 -OutFile install.ps1
Get-Content install.ps1   # read it first

# 2. Run it
.\install.ps1

# 3. Clean up
Remove-Item install.ps1
```

Then open the interactive module installer:

```powershell
pstools
```

Arrow keys to navigate, Space to toggle, Enter to apply.

## PsTools Commands

| Command | Description |
|---------|-------------|
| `pstools` | Interactive installer TUI |
| `pstools list` | Show available modules and install state |
| `pstools update` | Re-download all installed modules |
| `pstools source list` | List configured module sources |
| `pstools source add <name> <owner/repo>` | Add a GitHub repo source |
| `pstools source add <name> folder:C:\path` | Add a local folder source |
| `pstools source remove <name>` | Remove a source |

## Modules

### Repo

Bookmark and navigate between repositories. Tab-completion, fuzzy "did you mean" suggestions, pipeable `Repo.Entry` output.

Config: `~/.config/pstools/repositories.json`

```powershell
repo go myproject        # cd to bookmarked repo
repo ls                  # list all repos (pipeable)
repo ls -r               # repos under current directory
repo rg myproject D:\src  # register a repo
repo rm myproject         # remove
repo mv old new           # rename
repo prune                # remove repos with invalid paths
repo config               # show config file path
```

### WorkProject

Toggle dev project stacks - services, IIS app pools/sites, Docker containers, generic background commands, and processes. Interactive TUI with suspend/resume and conflict detection.

Config: `~/.config/pstools/workproject.json`

```powershell
wp                  # interactive menu
wp myproject        # toggle a project
wp -Only webapp     # disable all others, enable webapp
wp myproject -Action Enable
wp myproject -Action Disable
```

**Resource types** in config:

| Key | What it manages |
|-----|-----------------|
| `services` | Windows services (start/stop + startup type toggle) |
| `iisAppPools` | IIS application pools |
| `iisSites` | IIS web sites |
| `docker` | Docker containers (image, ports, env, volumes) |
| `commands` | Background processes (start cmd, cwd, env, kill-by-PID) |
| `processes` | Processes to kill on disable (name + cmdLineMatch) |
| `readiness` | TCP port or HTTP URL checks before proceeding |

**Conflict detection** via `_requires`:

```json
{
  "_requires": { "dockerDaemon": "linux", "node": ">=22" }
}
```

Warns and blocks enable if Docker is in the wrong daemon mode or the wrong Node.js version is active. Override with `-Force`.

**Other commands:**

```powershell
Get-WorkProject           # table of all projects and state
Suspend-WorkProject       # save state, disable all
Resume-WorkProject        # restore saved state
wp-cleanup                # kill zombie shells, dedupe Spotify, clear old temp files
wp-cleanup -WhatIf        # dry run
```

### Silence

Kill a configurable list of noisy background processes.

Config: `~/.config/pstools/silence.txt` (one process name per line, `#` comments supported)

```powershell
silence              # kill all targets
silence -List        # show targets and running state with memory usage
silence -Add chrome  # add a target
silence -Add chrome, spotify  # add multiple
silence -Remove sqlwriter     # remove a target
silence -Verbose     # show per-process detail
silence -Quiet       # suppress output
```

### OpenCodeMcp

Toggle MCP servers in OpenCode config (`opencode.jsonc`) with an interactive TUI. Supports global and project-local scopes. Preserves JSONC comments on write.

```powershell
ocmcp                        # interactive menu
ocmcp -Name figma            # toggle a specific server
ocmcp -Name figma -Scope Local   # toggle in project-local config
```

### Dockersw

Switch Docker Desktop between Windows and Linux container mode.

```powershell
dockersw
```

### Reset-IISCache

Stop IIS, clear ASP.NET temporary files for all .NET Framework versions, restart IIS. Requires Administrator.

```powershell
Reset-IISCache
```

## Config Files

| File | Module | Description |
|------|--------|-------------|
| `sources.json` | PsTools | Module source registry |
| `repositories.json` | Repo | Bookmarked repositories |
| `workproject.json` | WorkProject | Project stack definitions |
| `workproject-state.json` | WorkProject | Suspend/resume state |
| `silence.txt` | Silence | Process kill targets |
| `pids/` | WorkProject | PID files for background commands |

All under `~/.config/pstools/`.

## Compatibility

- PowerShell 5.1 (Windows PowerShell) and PowerShell 7+ (pwsh)
- Windows only (IIS, Windows services, Docker Desktop)
