param location string
param resourceToken string
param tags object
param vnetName string
param subnetPrefix string = '10.42.3.0/24'
param privateIpAddress string = '10.42.3.4'
param bastionSubnetPrefix string = '10.42.4.0/26'

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: vnetName
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: 'azdcns${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Rdp-From-Bastion'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: bastionSubnetPrefix
          destinationAddressPrefix: privateIpAddress
        }
      }
      {
        name: 'Deny-Other-Inbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource outboundIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: 'azdcnatip${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2025-07-01' = {
  name: 'azdcnat${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: outboundIp.id
      }
    ]
  }
}

resource dcSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: vnet
  name: 'DomainControllerSubnet'
  properties: {
    addressPrefix: subnetPrefix
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: nsg.id
    }
    natGateway: {
      id: nat.id
    }
  }
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: vnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: bastionSubnetPrefix
    defaultOutboundAccess: false
  }
  dependsOn: [
    dcSubnet
  ]
}

output dcSubnetId string = dcSubnet.id
output bastionSubnetId string = bastionSubnet.id
output privateIp string = privateIpAddress
