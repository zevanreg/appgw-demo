#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigurationBase64
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$configuration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigurationBase64)) | ConvertFrom-Json
$domainName = [string] $configuration.domainName
$netbiosName = [string] $configuration.netbiosName
if ($domainName -notmatch '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') {
    throw 'domainName must be a valid multi-label DNS name.'
}
if ($netbiosName -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,14}$') {
    throw 'netbiosName must start with a letter and contain at most 15 letters, digits or hyphens.'
}

$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.DomainRole -ge 4) {
    if ($computer.Domain -ine $domainName) {
        throw "This VM is already a domain controller for $($computer.Domain), not $domainName."
    }
    Write-Output "Domain controller for $domainName already exists; no changes made."
    return
}
if ($computer.PartOfDomain) {
    throw 'Refusing to create a new forest on a domain-joined server.'
}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters') {
    throw 'AD DS promotion has already started. Restart the VM and verify promotion before retrying.'
}
if ([string]::IsNullOrWhiteSpace($configuration.dsrmPassword)) {
    throw 'A non-empty DSRM password is required.'
}
$dsrmPassword = ConvertTo-SecureString $configuration.dsrmPassword -AsPlainText -Force
$configuration = $null
$ConfigurationBase64 = $null

# Only the dedicated LUN 0 data disk may be initialized; never format an existing filesystem.
$disks = @(Get-Disk | Where-Object { $_.Location -match 'LUN 0$' -and -not $_.IsBoot -and -not $_.IsSystem })
if ($disks.Count -ne 1) {
    throw 'Expected exactly one non-system data disk at LUN 0.'
}
$disk = $disks[0]
$existingVolume = @(Get-Volume | Where-Object DriveLetter -eq 'F')
if ($disk.PartitionStyle -eq 'RAW') {
    if ($existingVolume.Count -ne 0) {
        throw 'F: is already in use; refusing to initialize the AD data disk.'
    }
    $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -DriveLetter F |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'ADData' -Confirm:$false | Out-Null
}
else {
    $partition = @(Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter -eq 'F')
    if ($partition.Count -ne 1 -or $existingVolume.Count -ne 1 -or $existingVolume[0].FileSystemLabel -ne 'ADData') {
        throw 'LUN 0 is not the expected F: ADData volume; refusing to modify it.'
    }
}

$feature = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
if (-not $feature.Success -or $feature.RestartNeeded -eq 'Yes') {
    throw 'AD DS feature installation did not finish without a restart. Inspect the feature result and restart before retrying.'
}
Import-Module ADDSDeployment
Install-ADDSForest -DomainName $domainName -DomainNetbiosName $netbiosName `
    -InstallDns -CreateDnsDelegation:$false `
    -DatabasePath 'F:\NTDS' -LogPath 'F:\NTDS' -SysvolPath 'F:\SYSVOL' `
    -SafeModeAdministratorPassword $dsrmPassword -NoRebootOnCompletion:$true -Force

Write-Output 'Forest promotion was initiated successfully. Restart this VM from Azure after provisioning completes, then run Configure-DemoDirectory.ps1 before installing Entra Connect.'
