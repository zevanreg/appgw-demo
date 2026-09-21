targetScope = 'subscription'

@description('The azd environment name. This value is supplied by main.parameters.json from AZURE_ENV_NAME.')
param environmentName string

@description('Azure region for the deployment. eastus2 was validated for the requested resource family in this subscription.')
param location string

@description('Resource group name created by azd for this environment.')
param resourceGroupName string = 'rg-${environmentName}'

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
  }
}

output RESOURCE_GROUP_ID string = resourceGroup.id
output APPLICATION_GATEWAY_FQDN string = resources.outputs.APPLICATION_GATEWAY_FQDN
output APPLICATION_GATEWAY_PUBLIC_IP string = resources.outputs.APPLICATION_GATEWAY_PUBLIC_IP
output LOGIC_APP_DEFAULT_HOSTNAME string = resources.outputs.LOGIC_APP_DEFAULT_HOSTNAME
output LOGIC_APP_NAME string = resources.outputs.LOGIC_APP_NAME
output STORAGE_ACCOUNT_NAME string = resources.outputs.STORAGE_ACCOUNT_NAME
