#Requires -Version 7.0
#Requires -Modules Az.Accounts, @{ ModuleName = 'SqlServer'; ModuleVersion = '22.0.0' }
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$')]
    [string] $ServerFqdn,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $DatabaseName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9_-]{1,128}$')]
    [string] $IdentityName,

    [Parameter(Mandatory)]
    [guid] $IdentityPrincipalId,

    [Parameter(Mandatory)]
    [guid] $TenantId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($DatabaseName -in @('master', 'tempdb', 'model', 'msdb')) {
    throw 'Select the application database, not a system database.'
}
if ($IdentityPrincipalId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty) {
    throw 'IdentityPrincipalId and TenantId must be non-empty GUIDs.'
}
$context = Get-AzContext
if ($null -eq $context -or $context.Tenant.Id -ne $TenantId.ToString()) {
    throw 'Run Connect-AzAccount as the SQL Entra administrator in the intended tenant first.'
}

# Azure SQL contained users use the service principal object ID, not the client ID.
$sid = '0x' + [BitConverter]::ToString($IdentityPrincipalId.ToByteArray()).Replace('-', '')
$query = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    IF DATABASE_PRINCIPAL_ID(N'$IdentityName') IS NULL
        CREATE USER [$IdentityName] WITH SID = $sid, TYPE = E;

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_principals
        WHERE name = N'$IdentityName' AND sid = $sid AND type = 'E'
    )
        THROW 50001, 'Existing database user does not match the managed identity. Review before changing grants.', 1;

    GRANT CONNECT TO [$IdentityName];
    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members
        WHERE role_principal_id = DATABASE_PRINCIPAL_ID(N'db_datareader')
          AND member_principal_id = DATABASE_PRINCIPAL_ID(N'$IdentityName')
    )
        ALTER ROLE db_datareader ADD MEMBER [$IdentityName];
    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members
        WHERE role_principal_id = DATABASE_PRINCIPAL_ID(N'db_datawriter')
          AND member_principal_id = DATABASE_PRINCIPAL_ID(N'$IdentityName')
    )
        ALTER ROLE db_datawriter ADD MEMBER [$IdentityName];

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT name AS IdentityName, CONVERT(uniqueidentifier, sid) AS PrincipalId,
    IS_ROLEMEMBER(N'db_datareader', name) AS CanRead,
    IS_ROLEMEMBER(N'db_datawriter', name) AS CanWrite
FROM sys.database_principals
WHERE name = N'$IdentityName' AND sid = $sid AND type = 'E';
"@

$token = Get-AzAccessToken -ResourceTypeName SqlDB -TenantId $TenantId.ToString()
$result = @(Invoke-Sqlcmd -ServerInstance "tcp:$ServerFqdn,1433" -Database $DatabaseName `
    -AccessToken $token.Token -Query $query -Encrypt Mandatory `
    -ConnectionTimeout 30 -QueryTimeout 60 -AbortOnError -DisableVariables -DisableCommands -ErrorAction Stop)
if ($result.Count -ne 1 -or $result[0].PrincipalId -ne $IdentityPrincipalId -or
    $result[0].CanRead -ne 1 -or $result[0].CanWrite -ne 1) {
    throw 'SQL managed identity user/role verification failed.'
}

[pscustomobject] @{
    Server = $ServerFqdn
    Database = $DatabaseName
    IdentityName = $IdentityName
    PrincipalId = $IdentityPrincipalId
    Verified = $true
}
