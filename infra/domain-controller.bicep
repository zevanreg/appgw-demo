param location string
param resourceToken string
param tags object
param dcSubnetId string
param bastionSubnetId string
param privateIpAddress string
param adminUsername string

@secure()
param adminPassword string

@secure()
param dsrmPassword string

param domainName string = 'ad.demo.test'
param netbiosName string = 'DEMO'
param vmSize string = 'Standard_D2s_v5'

var bootstrapScript = base64(loadTextContent('../scripts/Initialize-DemoForest.ps1'))

resource bastionIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: 'azbasip${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-07-01' = {
  name: 'azbas${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionIp.id
          }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: 'azdcnic${resourceToken}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: dcSubnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: 'azdc${resourceToken}'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'demodc01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 32
          caching: 'None'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource bootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'InstallDemoForest'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    // Keep the DSRM password and script arguments out of public extension settings.
    protectedSettings: {
      commandToExecute: format('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'{0}\')))) -ConfigurationBase64 \'{1}\'"', bootstrapScript, base64(string({
        domainName: domainName
        netbiosName: netbiosName
        dsrmPassword: dsrmPassword
      })))
    }
  }
}

output vmName string = vm.name
output privateIp string = privateIpAddress
output nicName string = nic.name
output bastionName string = bastion.name
