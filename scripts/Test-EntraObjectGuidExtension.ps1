#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,
    [Parameter(Mandatory)]
    [string] $UserId,
    [Parameter(Mandatory)]
    [guid] $ExpectedObjectGuid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$context = Get-MgContext
if (-not $context -or $context.TenantId -ne $TenantId.ToString()) {
    throw 'First use Connect-MgGraph with the intended tenant and Application.Read.All, User.Read.All delegated permissions.'
}

function Get-GraphCollection {
    param([string] $Uri)
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $response.value
        $Uri = if ($response.ContainsKey('@odata.nextLink')) { $response['@odata.nextLink'] } else { $null }
    } while ($Uri)
}

$apps = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/v1.0/applications?$filter=displayName%20eq%20%27Tenant%20Schema%20Extension%20App%27&$select=id,appId')
if ($apps.Count -ne 1) {
    throw "Expected exactly one Tenant Schema Extension App; found $($apps.Count). Complete the Entra Connect wizard first."
}
$appObjectId = [Uri]::EscapeDataString($apps[0].id)
$properties = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/extensionProperties")
$extensions = @($properties | Where-Object {
    $_.name -cmatch '^extension_[a-fA-F0-9]{32}_objectGUID$' -and
    $_.isSyncedFromOnPremises -eq $true -and
    $_.targetObjects -contains 'User'
})
if ($extensions.Count -ne 1) {
    throw "Expected exactly one synced user objectGUID directory extension; found $($extensions.Count). Check the Entra Connect directory-extension selection."
}
$extensionName = $extensions[0].name
$encodedUserId = [Uri]::EscapeDataString($UserId)
$uri = 'https://graph.microsoft.com/v1.0/users/{0}?$select=id,userPrincipalName,onPremisesSyncEnabled,{1}' -f $encodedUserId, $extensionName
$user = Invoke-MgGraphRequest -Method GET -Uri $uri
if ($user.onPremisesSyncEnabled -ne $true) {
    throw 'The selected Entra user is not synchronized from AD.'
}
if (-not $user.ContainsKey($extensionName) -or [string]::IsNullOrWhiteSpace([string] $user[$extensionName])) {
    throw "The user has no value for $extensionName. Check OU scope and successful import, synchronization and export."
}
$expectedBase64 = [Convert]::ToBase64String($ExpectedObjectGuid.ToByteArray())
$actualValue = [string] $user[$extensionName]
if ($actualValue -cne $expectedBase64) {
    throw "The directory extension does not match the expected AD objectGUID ($ExpectedObjectGuid). Check the selected AD and Entra users."
}

[pscustomobject] @{
    UserPrincipalName = $user.userPrincipalName
    ExtensionName = $extensionName
    ExtensionValue = $actualValue
    ObjectGuid = $ExpectedObjectGuid
    Verified = $true
}
