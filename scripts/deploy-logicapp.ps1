param(
    [string] $ResourceGroupName = $env:AZURE_RESOURCE_GROUP,
    [string] $LogicAppName = $env:LOGIC_APP_NAME,
    [string] $SourcePath = (Join-Path $PSScriptRoot '..' 'src' 'logicapp')
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogicAppName)) {
    $LogicAppName = (azd env get-value LOGIC_APP_NAME 2>$null)
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = (azd env get-value AZURE_RESOURCE_GROUP 2>$null)
}

if ([string]::IsNullOrWhiteSpace($LogicAppName) -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw 'Set LOGIC_APP_NAME and AZURE_RESOURCE_GROUP, or run this from an initialized azd environment after provisioning.'
}

if (-not (Test-Path $SourcePath)) {
    throw "Logic App source path not found: $SourcePath"
}

$packagePath = Join-Path ([System.IO.Path]::GetTempPath()) "logicapp-$LogicAppName.zip"
if (Test-Path $packagePath) {
    Remove-Item $packagePath -Force
}

Compress-Archive -Path (Join-Path $SourcePath '*') -DestinationPath $packagePath -Force

Write-Host "Deploying workflow package to $LogicAppName in $ResourceGroupName."
Write-Host 'The Logic App has public access disabled, so run this from a machine that can resolve and reach the app private endpoint.'

az webapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $LogicAppName `
    --src $packagePath
