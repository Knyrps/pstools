Set-StrictMode -Version Latest

$script:ApiUrl   = 'https://api.github.com/copilot_internal/user'
$script:BarWidth = 20

function Get-CopilotPremiumUsage {
    <#
    .SYNOPSIS
        Returns your GitHub Copilot premium request usage.
    .DESCRIPTION
        Calls the undocumented internal Copilot API (the same endpoint
        Visual Studio uses for "Copilot Consumptions") and returns quota,
        usage, overage, and reset information as a PSCustomObject.
    .PARAMETER Token
        A GitHub PAT (classic with 'copilot' scope).
        Falls back to $env:COPILOT_TOKEN_BUSINESS if omitted.
    .EXAMPLE
        Get-CopilotPremiumUsage
    .EXAMPLE
        Get-CopilotPremiumUsage -Token "ghp_xxxxxxxxxxxx"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Token
    )

    if (-not $Token) { $Token = $env:COPILOT_TOKEN_BUSINESS }
    if (-not $Token) {
        throw "No token supplied. Pass -Token or set `$env:COPILOT_TOKEN_BUSINESS."
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
    }

    try {
        $response = Invoke-RestMethod -Uri $script:ApiUrl -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        throw "API call failed: $_"
    }

    $premium = $response.quota_snapshots.premium_interactions
    if (-not $premium) {
        throw "No premium_interactions data in response. Check that your token has the copilot scope."
    }

    $entitlement  = [int]$premium.entitlement
    $remaining    = [int]$premium.remaining
    $includedUsed = $entitlement - $remaining
    $overage      = [int]$premium.overage_count
    $totalUsed    = $includedUsed + $overage
    $resetDisplay = Resolve-ResetDate $response

    if ($entitlement -gt 0) {
        $pct = [math]::Round($totalUsed / $entitlement * 100, 2)
    } else {
        $pct = 0
    }

    [PSCustomObject]@{
        Plan                   = $response.copilot_plan
        Entitlement            = $entitlement
        IncludedUsed           = $includedUsed
        TotalUsed              = $totalUsed
        Remaining              = $remaining
        PercentUsed            = $pct
        AdditionalPaidRequests = $overage
        OveragePermitted       = [bool]$premium.overage_permitted
        ResetDate              = $resetDisplay.Date
        ResetDisplay           = $resetDisplay.Friendly
    }
}

function Show-CopilotPremiumUsage {
    <#
    .SYNOPSIS
        Renders a color-coded usage bar for GitHub Copilot premium requests.
    .DESCRIPTION
        Fetches usage via Get-CopilotPremiumUsage and prints a two-line
        summary with full-width dividers.

        Color tiers:
          Cyan       < 100%
          Yellow     100 - 999%
          Red/DarkRed >= 1000%

        Pulses when usage is at or near 1000%.
    .PARAMETER Token
        Passed through to Get-CopilotPremiumUsage.
    .EXAMPLE
        Show-CopilotPremiumUsage
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Token
    )

    $params = @{}
    if ($Token) { $params.Token = $Token }

    $cu  = Get-CopilotPremiumUsage @params -ErrorAction Stop
    $pct = $cu.PercentUsed

    $width = [math]::Max([Console]::WindowWidth, 40)
    $div   = [string]::new([char]0x2500, $width)

    $colors = Get-TierColors $pct

    Write-Host $div -ForegroundColor $colors.Divider

    if ($pct -ge 900) {
        $pairs = Get-PulsePairs $pct

        for ($i = 0; $i -lt 6; $i++) {
            $p = $pairs[$i % 2]
            Write-UsageBar $cu $p.Bar $p.Over $p.Pct $p.Otx
            Start-Sleep -Milliseconds 300
            [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
        }

        Write-UsageBar $cu $colors.Bar $colors.Over $colors.Pct $colors.Otx
        Write-Host ''
    } else {
        Write-UsageBar $cu $colors.Bar $colors.Over $colors.Pct $colors.Otx
        Write-Host ''
    }

    Write-Host $div -ForegroundColor $colors.Divider
}

# --- private helpers ---

function Resolve-ResetDate {
    param([object]$Response)

    $raw = $Response.quota_reset_date_utc
    if (-not $raw) { $raw = $Response.quota_reset_date }

    $dt = [datetime]::MinValue
    if ($raw) {
        try   { $dt = [datetime]::Parse($raw) }
        catch { $dt = [datetime]::MinValue }
    }

    if ($dt -ne [datetime]::MinValue) {
        $local    = $dt.ToLocalTime()
        $daysLeft = [math]::Ceiling(($local - (Get-Date)).TotalDays)
        $datePart = $local.ToString('MMM d')
        if     ($daysLeft -le 0) { $friendly = "$datePart (today)" }
        elseif ($daysLeft -eq 1) { $friendly = "$datePart (tomorrow)" }
        else                     { $friendly = "$datePart (in $daysLeft days)" }
    } else {
        $friendly = "$raw"
    }

    return @{ Date = $dt; Friendly = $friendly }
}

function Get-TierColors {
    param([double]$Pct)

    if ($Pct -ge 1000) {
        return @{ Bar='Red'; Over='DarkRed'; Pct='Red'; Otx='DarkRed'; Divider='DarkRed' }
    }
    if ($Pct -ge 100) {
        return @{ Bar='Yellow'; Over='Yellow'; Pct='Yellow'; Otx='Yellow'; Divider='DarkYellow' }
    }
    return @{ Bar='Cyan'; Over='Cyan'; Pct='Cyan'; Otx='Cyan'; Divider='DarkCyan' }
}

function Get-PulsePairs {
    param([double]$Pct)

    if ($Pct -ge 1000) {
        return @(
            @{ Bar='Red';     Over='DarkRed'; Pct='Red';     Otx='DarkRed' },
            @{ Bar='DarkRed'; Over='Black';   Pct='DarkRed'; Otx='Black'   }
        )
    }
    return @(
        @{ Bar='Yellow'; Over='Yellow'; Pct='Yellow'; Otx='Yellow' },
        @{ Bar='Red';    Over='Red';    Pct='Red';    Otx='Red'    }
    )
}

function Write-UsageBar {
    param(
        [object]$Usage,
        [string]$BarColor,
        [string]$OverBarColor,
        [string]$PctColor,
        [string]$OverTxtColor
    )

    $ent = [math]::Max($Usage.Entitlement, 1)
    $full  = [char]0x2588
    $empty = [char]0x2591
    $pad   = ' ' * 60

    $inclChars  = [math]::Min([math]::Round($Usage.IncludedUsed / $ent * $script:BarWidth), $script:BarWidth)
    $emptyChars = $script:BarWidth - $inclChars
    $overRatio  = $Usage.AdditionalPaidRequests / $ent
    $overChars  = [math]::Min([math]::Round([math]::Sqrt($overRatio) * $script:BarWidth), 40)

    # line 1: bar + percent
    Write-Host "`r  [" -NoNewline -ForegroundColor Gray
    if ($inclChars -gt 0) {
        Write-Host ([string]::new($full, $inclChars)) -NoNewline -ForegroundColor $BarColor
    }
    if ($emptyChars -gt 0) {
        Write-Host ([string]::new($empty, $emptyChars)) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host '|' -NoNewline -ForegroundColor Gray
    if ($overChars -gt 0) {
        Write-Host ([string]::new($full, $overChars)) -NoNewline -ForegroundColor $OverBarColor
    }
    Write-Host ("]  {0}%$pad" -f $Usage.PercentUsed) -ForegroundColor $PctColor

    # line 2: details
    Write-Host ("`r  {0}/{1} included" -f $Usage.IncludedUsed, $Usage.Entitlement) -NoNewline -ForegroundColor Gray
    if ($Usage.AdditionalPaidRequests -gt 0) {
        Write-Host ("  +{0} PAID OVERAGE" -f $Usage.AdditionalPaidRequests) -NoNewline -ForegroundColor $OverTxtColor
    }
    Write-Host ("  resets {0}$pad" -f $Usage.ResetDisplay) -NoNewline -ForegroundColor DarkGray
}

Export-ModuleMember -Function Get-CopilotPremiumUsage, Show-CopilotPremiumUsage
