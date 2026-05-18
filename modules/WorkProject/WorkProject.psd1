@{
    RootModule = 'WorkProject.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'b5e1d2a4-6c4f-4b9e-9a3e-8c7d1f4b2e90'
    Author = 'valentin.pommee'
    Description = 'Toggle dev project stacks (services, IIS app pools, processes) interactively or by name.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Set-WorkProject','Get-WorkProject','Suspend-WorkProject','Resume-WorkProject','Invoke-WorkspaceCleanup')
    AliasesToExport = @('wp','wp-cleanup')
    CmdletsToExport = @()
    VariablesToExport = @()
}
