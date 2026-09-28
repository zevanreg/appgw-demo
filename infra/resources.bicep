targetScope = 'resourceGroup'

@description('The azd environment name.')
param environmentName string

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

param dcAdminUsername string

@secure()
param dcAdminPassword string

@secure()
param dsrmPassword string

param adDomainName string = 'ad.demo.test'
param adNetbiosName string = 'DEMO'

@description('Object ID of the Microsoft Entra group or user administering SQL. Never use the web app identity.')
@minLength(36)
@maxLength(36)
param sqlAdminObjectId string

@description('Display name of the SQL Microsoft Entra administrator.')
@minLength(1)
param sqlAdminLogin string

@allowed([
  'Group'
  'User'
])
param sqlAdminPrincipalType string = 'Group'

@description('Windows App Service Standard SKU, separate from the Logic App Workflow Standard plan.')
@allowed([
  'S1'
  'S2'
  'S3'
])
param webAppPlanSkuName string = 'S1'

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Subnet prefix for Application Gateway.')
param appGatewaySubnetPrefix string = '10.42.0.0/24'

@description('Subnet prefix for private endpoints.')
param privateEndpointSubnetPrefix string = '10.42.1.0/24'

@description('Subnet prefix delegated for Logic App outbound virtual network integration.')
param logicAppIntegrationSubnetPrefix string = '10.42.2.0/24'

@description('Dedicated subnet for Windows web app outbound VNet integration.')
param webAppIntegrationSubnetPrefix string = '10.42.5.0/24'

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

@description('Application Gateway HTTP origin port, reachable only from Front Door. The backend connection to the Windows web app uses HTTPS.')
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
var frontDoorName = 'azafd${resourceToken}'
var frontDoorEndpointName = 'azfde${resourceToken}'
var webAppName = 'azweb${resourceToken}'
var webAppIdentityName = 'azwid${resourceToken}'
var webAppIntegrationSubnetName = 'azwint${resourceToken}'
var sqlServerName = 'azsql${resourceToken}'
var sqlDatabaseName = 'appdb'

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

resource webAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: webAppIdentityName
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
        name: 'Allow-Http-From-FrontDoor'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(appGatewayListenerPort)
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
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
      {
        name: 'Deny-Other-Inbound'
        properties: {
          priority: 130
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

resource webAppPrivateEndpointAsg 'Microsoft.Network/applicationSecurityGroups@2025-07-01' = {
  name: 'azwasg${resourceToken}'
  location: location
  tags: baseTags
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: 'azpensg${resourceToken}'
  location: location
  tags: baseTags
  properties: {
    securityRules: [
      {
        name: 'Allow-WebApp-Https-From-AppGateway'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: appGatewaySubnetPrefix
          destinationApplicationSecurityGroups: [
            {
              id: webAppPrivateEndpointAsg.id
            }
          ]
        }
      }
      {
        name: 'Deny-Other-WebApp-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationApplicationSecurityGroups: [
            {
              id: webAppPrivateEndpointAsg.id
            }
          ]
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
    privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
    networkSecurityGroup: {
      id: privateEndpointNsg.id
    }
  }
  dependsOn: [
    appGatewaySubnet
  ]
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
  dependsOn: [
    privateEndpointSubnet
  ]
}

resource webAppIntegrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: webAppIntegrationSubnetName
  properties: {
    addressPrefix: webAppIntegrationSubnetPrefix
    delegations: [
      {
        name: 'azdlw${resourceToken}'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
  dependsOn: [
    logicAppIntegrationSubnet
  ]
}

// Finish all subnet writes before creating any NICs, private endpoints or VNet-integrated services.
module domainControllerNetwork 'domain-controller-network.bicep' = {
  name: 'domain-controller-network'
  params: {
    location: location
    resourceToken: resourceToken
    tags: baseTags
    vnetName: virtualNetwork.name
  }
  dependsOn: [
    webAppIntegrationSubnet
  ]
}

module domainController 'domain-controller.bicep' = {
  name: 'domain-controller'
  params: {
    location: location
    resourceToken: resourceToken
    tags: baseTags
    dcSubnetId: domainControllerNetwork.outputs.dcSubnetId
    bastionSubnetId: domainControllerNetwork.outputs.bastionSubnetId
    privateIpAddress: domainControllerNetwork.outputs.privateIp
    adminUsername: dcAdminUsername
    adminPassword: dcAdminPassword
    dsrmPassword: dsrmPassword
    domainName: adDomainName
    netbiosName: adNetbiosName
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
  dependsOn: [
    domainControllerNetwork
  ]
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
    domainControllerNetwork
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
  dependsOn: [
    domainControllerNetwork
  ]
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

resource webAppPlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'azwsp${resourceToken}'
  location: location
  tags: baseTags
  kind: 'app'
  sku: {
    name: webAppPlanSkuName
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    reserved: false
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlServerName
  location: location
  tags: baseTags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: tenant().tenantId
      principalType: sqlAdminPrincipalType
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: baseTags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    maxSizeBytes: 2147483648
    requestedBackupStorageRedundancy: 'Local'
  }
}

resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink${environment().suffixes.sqlServerHostname}'
  location: 'global'
  tags: baseTags
}

resource sqlPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sqlPrivateDnsZone
  name: 'azvsql${resourceToken}'
  location: 'global'
  tags: baseTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'azpesql${resourceToken}'
  location: location
  tags: baseTags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'azscsql${resourceToken}'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    domainControllerNetwork
  ]
}

resource sqlPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: sqlPrivateEndpoint
  name: 'azdgsql${resourceToken}'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: sqlPrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    sqlPrivateDnsLink
  ]
}

resource webApp 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  kind: 'app'
  tags: union(baseTags, {
    'azd-service-name': 'webapp'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${webAppIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: webAppPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    clientAffinityEnabled: false
    virtualNetworkSubnetId: webAppIntegrationSubnet.id
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'AZURE_CLIENT_ID'
          value: webAppIdentity.properties.clientId
        }
        {
          name: 'SQL_SERVER_FQDN'
          value: sqlServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'SQL_DATABASE_NAME'
          value: sqlDatabase.name
        }
      ]
      connectionStrings: [
        {
          name: 'MicrosoftDataSqlClient'
          type: 'SQLAzure'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabase.name};Authentication=Active Directory Managed Identity;User Id=${webAppIdentity.properties.clientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
        }
        {
          name: 'SystemDataSqlClient'
          type: 'SQLAzure'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabase.name};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
        }
      ]
    }
  }
  dependsOn: [
    domainControllerNetwork
    sqlPrivateDnsZoneGroup
  ]
}

resource webAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'azpew${resourceToken}'
  location: location
  tags: baseTags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    applicationSecurityGroups: [
      {
        id: webAppPrivateEndpointAsg.id
      }
    ]
    privateLinkServiceConnections: [
      {
        name: 'azscw${resourceToken}'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
  dependsOn: [
    domainControllerNetwork
  ]
}

resource webAppPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: webAppPrivateEndpoint
  name: 'azdgw${resourceToken}'
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

resource frontDoor 'Microsoft.Cdn/profiles@2025-04-15' = {
  name: frontDoorName
  location: 'global'
  tags: baseTags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 30
  }
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-04-15' = {
  parent: frontDoor
  name: frontDoorEndpointName
  location: 'global'
  tags: baseTags
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2025-04-15' = {
  parent: frontDoor
  name: 'app-gateway'
  properties: {
    sessionAffinityState: 'Disabled'
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
  }
}

resource frontDoorOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2025-04-15' = {
  parent: frontDoorOriginGroup
  name: 'app-gateway'
  properties: {
    hostName: publicIp.properties.dnsSettings.fqdn
    originHostHeader: frontDoorEndpoint.properties.hostName
    httpPort: appGatewayListenerPort
    httpsPort: 443
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    priority: 1
    weight: 1000
  }
  dependsOn: [
    applicationGateway
  ]
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2025-04-15' = {
  parent: frontDoorEndpoint
  name: 'web-app'
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    frontDoorOrigin
  ]
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
    customRules: [
      // Header value comparisons alone do not reject a missing header.
      {
        name: 'BlockMissingFrontDoorId'
        priority: 1
        ruleType: 'MatchRule'
        action: 'Block'
        state: 'Enabled'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RequestHeaders'
                selector: 'X-Azure-FDID'
              }
            ]
            operator: 'Any'
            negationConditon: true
            matchValues: []
          }
        ]
      }
      {
        name: 'BlockOtherFrontDoorIds'
        priority: 2
        ruleType: 'MatchRule'
        action: 'Block'
        state: 'Enabled'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RequestHeaders'
                selector: 'X-Azure-FDID'
              }
            ]
            operator: 'Equal'
            negationConditon: true
            matchValues: [
              toLower(frontDoor.properties.frontDoorId)
            ]
            transforms: [
              'Lowercase'
            ]
          }
        ]
      }
    ]
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
              fqdn: webApp.properties.defaultHostName
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
          host: webApp.properties.defaultHostName
          interval: 30
          match: {
            statusCodes: [
              '200-399'
              '401'
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
    webAppPrivateDnsZoneGroup
    domainControllerNetwork
  ]
}

resource frontDoorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsfd${resourceToken}'
  scope: frontDoor
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'FrontDoorAccessLog'
        enabled: true
      }
      {
        category: 'FrontDoorHealthProbeLog'
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

resource webAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azdsw${resourceToken}'
  scope: webApp
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

output FRONT_DOOR_NAME string = frontDoor.name
output FRONT_DOOR_ID string = frontDoor.properties.frontDoorId
output FRONT_DOOR_HOSTNAME string = frontDoorEndpoint.properties.hostName
output FRONT_DOOR_URL string = 'https://${frontDoorEndpoint.properties.hostName}'
output APPLICATION_GATEWAY_FQDN string = publicIp.properties.dnsSettings.fqdn
output APPLICATION_GATEWAY_PUBLIC_IP string = publicIp.properties.ipAddress
output LOGIC_APP_DEFAULT_HOSTNAME string = logicApp.properties.defaultHostName
output LOGIC_APP_NAME string = logicApp.name
output STORAGE_ACCOUNT_NAME string = storage.name
output APP_SERVICE_NAME string = webApp.name
output APP_SERVICE_DEFAULT_HOSTNAME string = webApp.properties.defaultHostName
output WEB_APP_IDENTITY_NAME string = webAppIdentity.name
output WEB_APP_IDENTITY_CLIENT_ID string = webAppIdentity.properties.clientId
output WEB_APP_IDENTITY_PRINCIPAL_ID string = webAppIdentity.properties.principalId
output SQL_SERVER_FQDN string = sqlServer.properties.fullyQualifiedDomainName
output SQL_DATABASE_NAME string = sqlDatabase.name
output SQL_TENANT_ID string = tenant().tenantId
output DOMAIN_CONTROLLER_NAME string = domainController.outputs.vmName
output DOMAIN_CONTROLLER_PRIVATE_IP string = domainController.outputs.privateIp
output DOMAIN_CONTROLLER_NIC_NAME string = domainController.outputs.nicName
output AD_DOMAIN_NAME string = adDomainName
output BASTION_NAME string = domainController.outputs.bastionName
