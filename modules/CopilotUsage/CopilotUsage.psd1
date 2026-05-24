@{
    RootModule        = 'CopilotUsage.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3b4c5d6-e7f8-4a9b-0c1d-2e3f4a5b6c7d'
    Author            = 'Valentin Pommee'
    Description       = 'Show GitHub Copilot premium request usage, overage, and quota from the internal API.'
    FunctionsToExport = @('Get-CopilotPremiumUsage', 'Show-CopilotPremiumUsage')
    AliasesToExport   = @()
}
