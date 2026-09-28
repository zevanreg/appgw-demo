#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory, DnsServer
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$')]
    [string] $VerifiedUpnSuffix,
    [string] $DomainName = 'ad.demo.test',
    [string] $PrivateIpAddress = '10.42.3.4'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.DomainRole -lt 4 -or $computer.Domain -ine $DomainName) {
    throw "Run this on the restarted domain controller for $DomainName."
}
if ($VerifiedUpnSuffix -match '\.(test|local|invalid|example)$' -or $VerifiedUpnSuffix -ieq $DomainName) {
    throw 'Use a domain verified in your Entra tenant, not the private demo forest name.'
}

# Forward non-AD queries to Azure so linked private DNS zones continue to resolve.
Set-DnsServerForwarder -IPAddress '168.63.129.16'
$interfaces = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $PrivateIpAddress)
if ($interfaces.Count -ne 1) {
    throw "Expected one network interface with the Azure-assigned address $PrivateIpAddress."
}
Set-DnsClientServerAddress -InterfaceIndex $interfaces[0].InterfaceIndex -ServerAddresses '127.0.0.1'
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -Server '127.0.0.1' -ErrorAction Stop | Out-Null
Resolve-DnsName -Name 'login.microsoftonline.com' -Server '127.0.0.1' -ErrorAction Stop | Out-Null

$forest = Get-ADForest
if ($forest.UPNSuffixes -notcontains $VerifiedUpnSuffix) {
    Set-ADForest -Identity $forest.Name -UPNSuffixes @{ Add = $VerifiedUpnSuffix }
}
$domain = Get-ADDomain
$ouName = 'SyncedDemoUsers'
$ouDn = "OU=$ouName,$($domain.DistinguishedName)"
$existingOu = @(Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -SearchBase $domain.DistinguishedName -SearchScope OneLevel)
if ($existingOu.Count -eq 0) {
    New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName -ProtectedFromAccidentalDeletion $true
}

Write-Output "Directory ready. Create nonprivileged test users only in $ouDn with UPNs ending in @$VerifiedUpnSuffix."
Write-Output 'Install Entra Connect using Custom settings, scope synchronization to that OU, and select user objectGUID under Directory extension attribute sync.'
Write-Output 'This script does not configure the tenant or enable synchronization.'
