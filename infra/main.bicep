targetScope = 'subscription'

@description('The azd environment name. This value is supplied by main.parameters.json from AZURE_ENV_NAME.')
param environmentName string

@description('Azure region for the deployment. eastus2 was validated for the requested resource family in this subscription.')
param location string

@description('Resource group name created by azd for this environment.')
param resourceGroupName string = 'rg-${environmentName}'

@description('Local administrator; becomes the administrator of the new demo forest after promotion.')
param dcAdminUsername string = 'demoadmin'

@secure()
@description('Strong, unique VM administrator password. Supply securely at deployment time.')
param dcAdminPassword string

@secure()
@description('Separate Directory Services Restore Mode password for the new forest.')
param dsrmPassword string

@description('DNS name of the new, isolated demo AD forest.')
param adDomainName string = 'ad.demo.test'

@description('NetBIOS name for the new demo forest.')
@minLength(1)
@maxLength(15)
param adNetbiosName string = 'DEMO'

@description('Object ID of an existing Entra group or user in the deployment tenant, used only for SQL administration.')
@minLength(36)
@maxLength(36)
param sqlAdminObjectId string

@description('Display name of that Entra SQL administrator.')
@minLength(1)
param sqlAdminLogin string

@allowed([
  'Group'
  'User'
])
param sqlAdminPrincipalType string = 'Group'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: {
    'azd-env-name': environmentName
  }
}

module resources 'resources.bicep' = {
  name: 'azdep-${environmentName}'
  scope: resourceGroup
  params: {
    environmentName: environmentName
    location: location
    dcAdminUsername: dcAdminUsername
    dcAdminPassword: dcAdminPassword
    dsrmPassword: dsrmPassword
    adDomainName: adDomainName
    adNetbiosName: adNetbiosName
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPrincipalType: sqlAdminPrincipalType
  }
}

output RESOURCE_GROUP_ID string = resourceGroup.id
output FRONT_DOOR_NAME string = resources.outputs.FRONT_DOOR_NAME
output FRONT_DOOR_ID string = resources.outputs.FRONT_DOOR_ID
output FRONT_DOOR_HOSTNAME string = resources.outputs.FRONT_DOOR_HOSTNAME
output FRONT_DOOR_URL string = resources.outputs.FRONT_DOOR_URL
output APPLICATION_GATEWAY_FQDN string = resources.outputs.APPLICATION_GATEWAY_FQDN
output APPLICATION_GATEWAY_PUBLIC_IP string = resources.outputs.APPLICATION_GATEWAY_PUBLIC_IP
output LOGIC_APP_DEFAULT_HOSTNAME string = resources.outputs.LOGIC_APP_DEFAULT_HOSTNAME
output LOGIC_APP_NAME string = resources.outputs.LOGIC_APP_NAME
output STORAGE_ACCOUNT_NAME string = resources.outputs.STORAGE_ACCOUNT_NAME
output APP_SERVICE_NAME string = resources.outputs.APP_SERVICE_NAME
output APP_SERVICE_DEFAULT_HOSTNAME string = resources.outputs.APP_SERVICE_DEFAULT_HOSTNAME
output WEB_APP_IDENTITY_NAME string = resources.outputs.WEB_APP_IDENTITY_NAME
output WEB_APP_IDENTITY_CLIENT_ID string = resources.outputs.WEB_APP_IDENTITY_CLIENT_ID
output WEB_APP_IDENTITY_PRINCIPAL_ID string = resources.outputs.WEB_APP_IDENTITY_PRINCIPAL_ID
output SQL_SERVER_FQDN string = resources.outputs.SQL_SERVER_FQDN
output SQL_DATABASE_NAME string = resources.outputs.SQL_DATABASE_NAME
output SQL_TENANT_ID string = resources.outputs.SQL_TENANT_ID
output DOMAIN_CONTROLLER_NAME string = resources.outputs.DOMAIN_CONTROLLER_NAME
output DOMAIN_CONTROLLER_PRIVATE_IP string = resources.outputs.DOMAIN_CONTROLLER_PRIVATE_IP
output DOMAIN_CONTROLLER_NIC_NAME string = resources.outputs.DOMAIN_CONTROLLER_NIC_NAME
output AD_DOMAIN_NAME string = resources.outputs.AD_DOMAIN_NAME
output BASTION_NAME string = resources.outputs.BASTION_NAME
