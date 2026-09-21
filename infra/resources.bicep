targetScope = 'resourceGroup'

@description('The azd environment name.')
param environmentName string

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Subnet prefix for Application Gateway.')
param appGatewaySubnetPrefix string = '10.42.0.0/24'

@description('Subnet prefix for private endpoints.')
param privateEndpointSubnetPrefix string = '10.42.1.0/24'

@description('Subnet prefix delegated for Logic App outbound virtual network integration.')
param logicAppIntegrationSubnetPrefix string = '10.42.2.0/24'

@description('Workflow Standard SKU for the Logic App Standard plan.')
@allowed([
  'WS1'
  'WS2'
  'WS3'
])
param logicAppPlanSkuName string = 'WS1'

@description('Minimum worker count for the Logic App Standard plan.')
@minValue(1)
param logicAppPlanCapacity int = 2

@description('Storage account redundancy. Standard_ZRS is used by default for resiliency.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
])
param storageSkuName string = 'Standard_ZRS'

@description('Application Gateway autoscale minimum capacity.')
@minValue(1)
param appGatewayMinCapacity int = 2

@description('Application Gateway autoscale maximum capacity.')
@minValue(2)
param appGatewayMaxCapacity int = 4

@description('Application Gateway listener port. The backend connection to the Logic App uses HTTPS.')
param appGatewayListenerPort int = 80

@description('Availability zones for zonal resources. Use an empty array in regions that do not support zones.')
param availabilityZones array = [
  '1'
  '2'
  '3'
]

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location, environmentName)
var baseTags = {
  workload: 'la-appgw-demo'
}

var applicationGatewayName = 'azagw${resourceToken}'
var appGatewayFrontendIpConfigName = 'azfip${resourceToken}'
var appGatewayFrontendPortName = 'azfpt${resourceToken}'
var appGatewayHttpListenerName = 'azlst${resourceToken}'
var appGatewayBackendPoolName = 'azbep${resourceToken}'
var appGatewayBackendSettingsName = 'azbes${resourceToken}'
var appGatewayProbeName = 'azprb${resourceToken}'
var appGatewayRuleName = 'azrul${resourceToken}'
var appGatewaySubnetName = 'azags${resourceToken}'
var appInsightsName = 'azai${resourceToken}'
var appServicePlanName = 'azasp${resourceToken}'
var contentShareName = 'azcnt${resourceToken}'
var identityName = 'azid${resourceToken}'
var logAnalyticsName = 'azlaw${resourceToken}'
var logicAppIntegrationSubnetName = 'azint${resourceToken}'
var logicAppName = 'azla${resourceToken}'
var logicAppPrivateEndpointName = 'azpel${resourceToken}'
var logicAppPrivateEndpointConnectionName = 'azscl${resourceToken}'
var logicAppPrivateDnsLinkName = 'azvwl${resourceToken}'
var logicAppPrivateDnsZoneGroupName = 'azdgl${resourceToken}'
var privateEndpointSubnetName = 'azpep${resourceToken}'
var publicIpName = 'azpip${resourceToken}'
var storageAccountName = 'azst${resourceToken}'
var vnetName = 'azvnt${resourceToken}'
var appGatewayNsgName = 'aznsg${resourceToken}'
var appGatewayWafPolicyName = 'azwaf${resourceToken}'

var storageDnsSuffix = environment().suffixes.storage
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${storageDnsSuffix};AccountKey=${storage.listKeys().keys[0].value}'

var storagePrivateLinkServices = [
  {
    service: 'blob'
    dnsZoneName: 'privatelink.blob.${storageDnsSuffix}'
    endpointPrefix: 'peb'
    connectionPrefix: 'scb'
    dnsLinkPrefix: 'vlb'
    zoneGroupPrefix: 'dgb'
  }
  {
    service: 'file'
    dnsZoneName: 'privatelink.file.${storageDnsSuffix}'
    endpointPrefix: 'pef'
    connectionPrefix: 'scf'
    dnsLinkPrefix: 'vlf'
    zoneGroupPrefix: 'dgf'
  }
  {
    service: 'queue'
    dnsZoneName: 'privatelink.queue.${storageDnsSuffix}'
    endpointPrefix: 'peq'
    connectionPrefix: 'scq'
    dnsLinkPrefix: 'vlq'
    zoneGroupPrefix: 'dgq'
  }
  {
    service: 'table'
    dnsZoneName: 'privatelink.table.${storageDnsSuffix}'
    endpointPrefix: 'pet'
    connectionPrefix: 'sct'
    dnsLinkPrefix: 'vlt'
    zoneGroupPrefix: 'dgt'
  }
]

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: logAnalyticsName
  location: location
  tags: baseTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: baseTags
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-05-31-preview' = {
  name: identityName
  location: location
  tags: baseTags
}

resource appGatewayNsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: appGatewayNsgName
  location: location
  tags: baseTags
  properties: {
    securityRules: [
      {
        name: 'Allow-Http-From-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(appGatewayListenerPort)
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-GatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: vnetName
  location: location
  tags: baseTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource appGatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: appGatewaySubnetName
  properties: {
    addressPrefix: appGatewaySubnetPrefix
    networkSecurityGroup: {
      id: appGatewayNsg.id
    }
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource logicAppIntegrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: logicAppIntegrationSubnetName
  properties: {
    addressPrefix: logicAppIntegrationSubnetPrefix
    delegations: [
      {
        name: 'azdlg${resourceToken}'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  tags: baseTags
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    isVersioningEnabled: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-08-01' = {
  parent: storage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource logicAppContentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-08-01' = {
  parent: fileService
  name: contentShareName
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: 5120
  }
}

resource storagePrivateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for service in storagePrivateLinkServices: {
  name: service.dnsZoneName
  location: 'global'
  tags: baseTags
}]

resource storagePrivateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (service, index) in storagePrivateLinkServices: {
  parent: storagePrivateDnsZones[index]
  name: 'az${service.dnsLinkPrefix}${resourceToken}'
  location: 'global'
  tags: baseTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}]

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2025-07-01' = [for service in storagePrivateLinkServices: {
  name: 'az${service.endpointPrefix}${resourceToken}'
  location: location
  tags: baseTags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'az${service.connectionPrefix}${resourceToken}'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            service.service
          ]
        }
      }
    ]
  }
}]

resource storagePrivateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = [for (service, index) in storagePrivateLinkServices: {
  parent: storagePrivateEndpoints[index]
  name: 'az${service.zoneGroupPrefix}${resourceToken}'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: service.service
        properties: {
          privateDnsZoneId: storagePrivateDnsZones[index].id
        }
      }
    ]
  }
  dependsOn: [
    storagePrivateDnsLinks[index]
  ]
}]

resource appServicePlan 'Microsoft.Web/serverFarms@2026-03-01-preview' = {
  name: appServicePlanName
  location: location
  kind: 'elastic'
  tags: baseTags
  sku: {
    name: logicAppPlanSkuName
    tier: 'WorkflowStandard'
    size: logicAppPlanSkuName
    family: 'WS'
    capacity: logicAppPlanCapacity
  }
  properties: {
    reserved: false
  }
}

resource logicApp 'Microsoft.Web/sites@2026-03-01-preview' = {
  name: logicAppName
  location: location
  kind: 'functionapp,workflowapp'
  tags: union(baseTags, {
    'azd-service-name': 'logicapp'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    clientAffinityEnabled: false
    enabled: true
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: logicAppIntegrationSubnet.id
    siteConfig: {
      alwaysOn: true
      cors: {
        allowedOrigins: []
        supportCredentials: false
      }
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      use32BitWorkerProcess: false
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTOVERVNET'
          value: '1'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: contentShareName
        }
        {
          name: 'WEBSITE_DNS_SERVER'
          value: '168.63.129.16'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
        {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '1'
        }
      ]
    }
  }
  dependsOn: [
    logicAppContentShare
    storagePrivateDnsZoneGroups
  ]
}

resource logicAppPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: baseTags
}

resource logicAppPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: logicAppPrivateDnsZone
  name: logicAppPrivateDnsLinkName
  location: 'global'
  tags: baseTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource logicAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: logicAppPrivateEndpointName
  location: location
  tags: baseTags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: logicAppPrivateEndpointConnectionName
        properties: {
          privateLinkServiceId: logicApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource logicAppPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: logicAppPrivateEndpoint
  name: logicAppPrivateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: logicAppPrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    logicAppPrivateDnsLink
  ]
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: publicIpName
  location: location
  zones: availabilityZones
  tags: baseTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower(applicationGatewayName)
    }
  }
}

resource appGatewayWafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2025-07-01' = {
  name: appGatewayWafPolicyName
  location: location
  tags: baseTags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: true
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource applicationGateway 'Microsoft.Network/applicationGateways@2025-07-01' = {
  name: applicationGatewayName
  location: location
  zones: availabilityZones
  tags: baseTags
  properties: {
    autoscaleConfiguration: {
      minCapacity: appGatewayMinCapacity
      maxCapacity: appGatewayMaxCapacity
    }
    firewallPolicy: {
      id: appGatewayWafPolicy.id
    }
    backendAddressPools: [
      {
        name: appGatewayBackendPoolName
        properties: {
          backendAddresses: [
            {
              fqdn: logicApp.properties.defaultHostName
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: appGatewayBackendSettingsName
        properties: {
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          port: 443
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', applicationGatewayName, appGatewayProbeName)
          }
          protocol: 'Https'
          requestTimeout: 30
        }
      }
    ]
    enableHttp2: true
    frontendIPConfigurations: [
      {
        name: appGatewayFrontendIpConfigName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: appGatewayFrontendPortName
        properties: {
          port: appGatewayListenerPort
        }
      }
    ]
    gatewayIPConfigurations: [
      {
        name: 'azgip${resourceToken}'
        properties: {
          subnet: {
            id: appGatewaySubnet.id
          }
        }
      }
    ]
    httpListeners: [
      {
        name: appGatewayHttpListenerName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, appGatewayFrontendIpConfigName)
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, appGatewayFrontendPortName)
          }
          protocol: 'Http'
        }
      }
    ]
    probes: [
      {
        name: appGatewayProbeName
        properties: {
          host: logicApp.properties.defaultHostName
          interval: 30
          match: {
            statusCodes: [
              '200-499'
            ]
          }
          path: '/'
          protocol: 'Https'
          timeout: 30
          unhealthyThreshold: 3
        }
      }
    ]
    requestRoutingRules: [
      {
        name: appGatewayRuleName
        properties: {
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, appGatewayBackendPoolName)
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, appGatewayBackendSettingsName)
          }
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, appGatewayHttpListenerName)
          }
          priority: 100
          ruleType: 'Basic'
        }
      }
    ]
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
  }
  dependsOn: [
    logicAppPrivateDnsZoneGroup
  ]
}

resource logicAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsl${resourceToken}'
  scope: logicApp
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource appGatewayDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsa${resourceToken}'
  scope: applicationGateway
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource storageBlobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsb${resourceToken}'
  scope: blobService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource storageFileDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsf${resourceToken}'
  scope: fileService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

output APPLICATION_GATEWAY_FQDN string = publicIp.properties.dnsSettings.fqdn
output APPLICATION_GATEWAY_PUBLIC_IP string = publicIp.properties.ipAddress
output LOGIC_APP_DEFAULT_HOSTNAME string = logicApp.properties.defaultHostName
output LOGIC_APP_NAME string = logicApp.name
output STORAGE_ACCOUNT_NAME string = storage.name
