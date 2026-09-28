#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $CompiledTemplatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$checks = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $MessagePattern)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-True ($null -ne $failure) "Expected failure matching: $MessagePattern"
    Assert-True ($failure.Exception.Message -match $MessagePattern) "Unexpected error: $failure"
}

function Get-TestScript {
    param([string] $Name)
    $tokens = $null
    $errors = $null
    $path = Join-Path $root 'scripts' $Name
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    Assert-True ($errors.Count -eq 0) "PowerShell syntax: $Name"
    # Omit host/module requirements only in this isolated mock harness, never in deployed scripts.
    $body = ($ast.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
    [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $body)
}

Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $tokens, [ref] $errors)
    Assert-True ($errors.Count -eq 0) "PowerShell syntax: $($_.Name)"
}

$main = Get-Content $CompiledTemplatePath -Raw | ConvertFrom-Json -AsHashtable
$workload = @($main.resources | Where-Object type -eq 'Microsoft.Resources/deployments')[0].properties.template
$resources = $workload.resources
$gateway = @($resources | Where-Object type -eq 'Microsoft.Network/applicationGateways')[0]
$web = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.kind -eq 'app' })[0]
$logic = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.kind -eq 'functionapp,workflowapp' })[0]
$plan = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/serverfarms' -and $_.sku.tier -eq 'Standard' })[0]
Assert-True ($plan.properties.reserved -eq $false) 'Windows Standard plan'
Assert-True ($workload.parameters.webAppPlanSkuName.defaultValue -eq 'S1') 'S1 default'
Assert-True ($web.properties.publicNetworkAccess -eq 'Disabled') 'Web app private only'
Assert-True ($logic.properties.publicNetworkAccess -eq 'Disabled') 'Logic App remains private'
Assert-True ($web.properties.serverFarmId -ne $logic.properties.serverFarmId) 'Separate web and workflow plans'
$gatewayJson = $gateway | ConvertTo-Json -Depth 100
Assert-True ($gatewayJson -notmatch "variables\('logicAppName'\)") 'No Logic App gateway references'
Assert-True ($gateway.properties.backendAddressPools.Count -eq 1) 'Only one backend pool'
Assert-True ($gateway.properties.backendAddressPools[0].properties.backendAddresses[0].fqdn -match "variables\('webAppName'\)") 'Web app backend'
Assert-True ($gateway.properties.probes[0].properties.host -match "variables\('webAppName'\)") 'Web app probe host'
$gatewayProbeStatuses = @($gateway.properties.probes[0].properties.match.statusCodes)
Assert-True ($gatewayProbeStatuses.Count -eq 2 -and $gatewayProbeStatuses -contains '200-399' -and
    $gatewayProbeStatuses -contains '401') 'Probe accepts healthy responses and the expected Easy Auth challenge only'
Assert-True ($gateway.properties.backendHttpSettingsCollection[0].properties.protocol -eq 'Https') 'TLS to backend'
$webPe = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Network/privateEndpoints' -and
    $_.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId -match "variables\('webAppName'\)"
})
Assert-True ($webPe.Count -eq 1) 'Web app has one private endpoint'
Assert-True ($webPe[0].properties.privateLinkServiceConnections[0].properties.groupIds[0] -eq 'sites') 'Web app sites subresource'

$frontDoors = @($resources | Where-Object type -eq 'Microsoft.Cdn/profiles')
Assert-True ($frontDoors.Count -eq 1) 'Exactly one Front Door profile'
$frontDoor = $frontDoors[0]
Assert-True ($frontDoor.sku.name -eq 'Standard_AzureFrontDoor' -and $frontDoor.location -eq 'global') 'Global Front Door Standard'
Assert-True (@($resources | Where-Object type -In @(
    'Microsoft.Network/frontDoorWebApplicationFirewallPolicies', 'Microsoft.Cdn/profiles/securityPolicies'
)).Count -eq 0) 'No Front Door WAF or security policy'
$frontDoorEndpoints = @($resources | Where-Object type -eq 'Microsoft.Cdn/profiles/afdEndpoints')
$frontDoorGroups = @($resources | Where-Object type -eq 'Microsoft.Cdn/profiles/originGroups')
$frontDoorOrigins = @($resources | Where-Object type -eq 'Microsoft.Cdn/profiles/originGroups/origins')
$frontDoorRoutes = @($resources | Where-Object type -eq 'Microsoft.Cdn/profiles/afdEndpoints/routes')
Assert-True ($frontDoorEndpoints.Count -eq 1 -and $frontDoorGroups.Count -eq 1 -and
    $frontDoorOrigins.Count -eq 1 -and $frontDoorRoutes.Count -eq 1) 'One complete Front Door route, with no bypass origin'
$frontDoorEndpoint = $frontDoorEndpoints[0]
$frontDoorGroup = $frontDoorGroups[0]
$frontDoorOrigin = $frontDoorOrigins[0]
$frontDoorRoute = $frontDoorRoutes[0]
$frontDoorDependency = "[resourceId('Microsoft.Cdn/profiles', variables('frontDoorName'))]"
$frontDoorEndpointDependency = "[resourceId('Microsoft.Cdn/profiles/afdEndpoints', variables('frontDoorName'), variables('frontDoorEndpointName'))]"
$frontDoorGroupDependency = "[resourceId('Microsoft.Cdn/profiles/originGroups', variables('frontDoorName'), 'app-gateway')]"
$frontDoorOriginDependency = "[resourceId('Microsoft.Cdn/profiles/originGroups/origins', variables('frontDoorName'), 'app-gateway', 'app-gateway')]"
$gatewayDependency = "[resourceId('Microsoft.Network/applicationGateways', variables('applicationGatewayName'))]"
Assert-True ($frontDoorEndpoint.dependsOn -contains $frontDoorDependency -and
    $frontDoorEndpoint.properties.enabledState -eq 'Enabled') 'Enabled endpoint belongs to the Front Door profile'
Assert-True ($frontDoorGroup.dependsOn -contains $frontDoorDependency) 'Origin group belongs to the same profile'
Assert-True ($frontDoorGroup.properties.sessionAffinityState -eq 'Disabled') 'No new session affinity'
Assert-True (-not $frontDoorGroup.properties.ContainsKey('healthProbeSettings')) 'Single-origin Front Door group has health probes disabled'
Assert-True ($frontDoorGroup.properties.loadBalancingSettings.sampleSize -eq 4 -and
    $frontDoorGroup.properties.loadBalancingSettings.successfulSamplesRequired -eq 3) 'Front Door health requires three of four successful samples'
Assert-True ($frontDoorOrigin.properties.hostName -eq $workload.outputs.APPLICATION_GATEWAY_FQDN.value) 'Front Door origin is the gateway, not App Service'
Assert-True ($frontDoorOrigin.properties.originHostHeader -eq $workload.outputs.FRONT_DOOR_HOSTNAME.value) 'Origin Host header preserves the public hostname for Easy Auth'
Assert-True ($frontDoorOrigin.properties.httpPort -eq "[parameters('appGatewayListenerPort')]") 'Front Door uses the configured gateway listener port'
Assert-True ($frontDoorOrigin.properties.enabledState -eq 'Enabled' -and
    $frontDoorOrigin.properties.enforceCertificateNameCheck -eq $true) 'Origin enabled without disabling certificate validation'
Assert-True ($frontDoorOrigin.dependsOn -contains $gatewayDependency -and
    $frontDoorOrigin.dependsOn -contains $frontDoorGroupDependency) 'Origin waits for the restricted gateway and origin group'
Assert-True ($frontDoorRoute.dependsOn -contains $frontDoorOriginDependency -and
    $frontDoorRoute.dependsOn -contains $frontDoorEndpointDependency) 'Route waits for the origin and endpoint'
Assert-True ($frontDoorRoute.properties.originGroup.id -eq $frontDoorGroupDependency) 'Route uses only the gateway origin group'
Assert-True ($frontDoorRoute.properties.enabledState -eq 'Enabled' -and
    $frontDoorRoute.properties.linkToDefaultDomain -eq 'Enabled') 'Route available on the Front Door default domain'
Assert-True ($frontDoorRoute.properties.patternsToMatch.Count -eq 1 -and
    $frontDoorRoute.properties.patternsToMatch[0] -eq '/*') 'All application paths go through the gateway'
Assert-True ($frontDoorRoute.properties.supportedProtocols.Count -eq 2 -and
    $frontDoorRoute.properties.supportedProtocols -contains 'Http' -and
    $frontDoorRoute.properties.supportedProtocols -contains 'Https' -and
    $frontDoorRoute.properties.httpsRedirect -eq 'Enabled') 'Client HTTP redirects to HTTPS'
Assert-True ($frontDoorRoute.properties.forwardingProtocol -eq 'HttpOnly') 'Origin protocol matches the existing HTTP-only gateway'
Assert-True (-not $frontDoorRoute.properties.ContainsKey('cacheConfiguration') -and
    -not $frontDoorRoute.properties.ContainsKey('originPath') -and
    -not $frontDoorRoute.properties.ContainsKey('ruleSets')) 'No caching, path rewriting, or alternate origin rules'

$gatewayNsg = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Network/networkSecurityGroups' -and $_.name -eq "[variables('appGatewayNsgName')]"
})[0]
$gatewayRules = @($gatewayNsg.properties.securityRules | Sort-Object { $_.properties.priority })
Assert-True ($gatewayRules.Count -eq 4) 'Gateway NSG has only Front Door, required infrastructure, and deny rules'
$frontDoorAllow = $gatewayRules[0].properties
Assert-True ($frontDoorAllow.access -eq 'Allow' -and $frontDoorAllow.direction -eq 'Inbound' -and
    $frontDoorAllow.protocol -eq 'Tcp' -and $frontDoorAllow.sourceAddressPrefix -eq 'AzureFrontDoor.Backend' -and
    $frontDoorAllow.sourcePortRange -eq '*' -and
    $frontDoorAllow.destinationPortRange -eq "[string(parameters('appGatewayListenerPort'))]" -and
    $frontDoorAllow.destinationAddressPrefix -eq '*') 'Only the Front Door backend service tag can reach the listener'
$gatewayManagerAllow = $gatewayRules[1].properties
Assert-True ($gatewayManagerAllow.access -eq 'Allow' -and $gatewayManagerAllow.direction -eq 'Inbound' -and
    $gatewayManagerAllow.sourceAddressPrefix -eq 'GatewayManager' -and
    $gatewayManagerAllow.destinationPortRange -eq '65200-65535') 'Required GatewayManager traffic preserved'
$loadBalancerAllow = $gatewayRules[2].properties
Assert-True ($loadBalancerAllow.access -eq 'Allow' -and $loadBalancerAllow.direction -eq 'Inbound' -and
    $loadBalancerAllow.sourceAddressPrefix -eq 'AzureLoadBalancer' -and
    $loadBalancerAllow.destinationPortRange -eq '*') 'Azure Load Balancer health probes preserved'
$gatewayDeny = $gatewayRules[3].properties
Assert-True ($gatewayDeny.access -eq 'Deny' -and $gatewayDeny.direction -eq 'Inbound' -and
    $gatewayDeny.sourceAddressPrefix -eq '*' -and $gatewayDeny.destinationAddressPrefix -eq '*' -and
    $gatewayDeny.protocol -eq '*' -and $gatewayDeny.sourcePortRange -eq '*' -and
    $gatewayDeny.destinationPortRange -eq '*' -and $gatewayDeny.priority -lt 65000) 'Explicit deny blocks Internet and VNet bypass before default NSG rules'

$wafPolicies = @($resources | Where-Object type -eq 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies')
Assert-True ($wafPolicies.Count -eq 1 -and $gateway.properties.sku.name -eq 'WAF_v2') 'Existing gateway WAF retained'
$waf = $wafPolicies[0]
Assert-True ($gateway.properties.firewallPolicy.id -eq "[resourceId('Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies', variables('appGatewayWafPolicyName'))]") 'Gateway uses the filtering WAF policy'
Assert-True ($waf.properties.policySettings.state -eq 'Enabled' -and
    $waf.properties.policySettings.mode -eq 'Prevention') 'Header checks block, rather than log only'
Assert-True ($waf.properties.managedRules.managedRuleSets[0].ruleSetType -eq 'OWASP' -and
    $waf.properties.managedRules.managedRuleSets[0].ruleSetVersion -eq '3.2') 'Existing OWASP protection preserved'
Assert-True ($waf.dependsOn -contains $frontDoorDependency) 'Header filtering uses the provisioned Front Door ID'
$headerRules = @($waf.properties.customRules | Sort-Object priority)
Assert-True ($headerRules.Count -eq 2) 'Both missing and incorrect Front Door ID are checked'
foreach ($rule in $headerRules) {
    Assert-True ($rule.action -eq 'Block' -and $rule.state -eq 'Enabled' -and
        $rule.ruleType -eq 'MatchRule' -and $rule.matchConditions.Count -eq 1) 'No custom Allow action bypasses managed rules'
    $condition = $rule.matchConditions[0]
    Assert-True ($condition.matchVariables.Count -eq 1 -and
        $condition.matchVariables[0].variableName -eq 'RequestHeaders' -and
        $condition.matchVariables[0].selector -eq 'X-Azure-FDID' -and
        $condition.negationConditon -eq $true -and
        -not $condition.ContainsKey('negationCondition')) 'Negated FDID condition uses the Azure API property spelling'
}
Assert-True ($headerRules[0].priority -eq 1 -and
    $headerRules[0].matchConditions[0].operator -eq 'Any' -and
    $headerRules[0].matchConditions[0].matchValues.Count -eq 0) 'Requests without an FDID header use the Any operator without match values'
$fdidCondition = $headerRules[1].matchConditions[0]
Assert-True ($headerRules[1].priority -eq 2 -and $fdidCondition.operator -eq 'Equal' -and
    $fdidCondition.matchValues.Count -eq 1 -and
    $fdidCondition.matchValues[0] -match "toLower\(reference\(resourceId\('Microsoft.Cdn/profiles', variables\('frontDoorName'\)\).*frontDoorId\)" -and
    $fdidCondition.transforms.Count -eq 1 -and $fdidCondition.transforms[0] -eq 'Lowercase') 'Only this profile ID passes an exact case-normalized comparison'

$frontDoorDiagnostics = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Insights/diagnosticSettings' -and $_.scope -match 'Microsoft.Cdn/profiles'
})
Assert-True ($frontDoorDiagnostics.Count -eq 1) 'Front Door diagnostics enabled'
Assert-True ($frontDoorDiagnostics[0].properties.workspaceId -match "variables\('logAnalyticsName'\)") 'Front Door uses existing Log Analytics'
Assert-True (@($frontDoorDiagnostics[0].properties.logs | Where-Object enabled -EQ $true).category -contains 'FrontDoorAccessLog' -and
    @($frontDoorDiagnostics[0].properties.logs | Where-Object enabled -EQ $true).category -contains 'FrontDoorHealthProbeLog') 'Access and origin probe logs enabled'
foreach ($output in @('FRONT_DOOR_NAME', 'FRONT_DOOR_ID', 'FRONT_DOOR_HOSTNAME', 'FRONT_DOOR_URL')) {
    Assert-True ($workload.outputs.ContainsKey($output) -and $main.outputs.ContainsKey($output) -and
        $main.outputs[$output].value -match "outputs\.$output\.value") "Front Door output exposed through azd: $output"
}
Assert-True ($workload.outputs.FRONT_DOOR_URL.value -match 'https://' -and
    $workload.outputs.FRONT_DOOR_URL.value -match "frontDoorEndpointName.*hostName") 'Public URL comes from the HTTPS Front Door endpoint'

Assert-True ($main.parameters.dcAdminPassword.type -eq 'secureString' -and $main.parameters.dsrmPassword.type -eq 'secureString') 'Secure root passwords'

$networkModules = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'domain-controller-network' })
Assert-True ($networkModules.Count -eq 1) 'Separate subnet provisioning barrier'
$networkModule = $networkModules[0]
$network = $networkModule.properties.template
$networkDependency = "[resourceId('Microsoft.Resources/deployments', 'domain-controller-network')]"
$appGatewaySubnetDependency = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('appGatewaySubnetName'))]"
$privateEndpointSubnetDependency = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('privateEndpointSubnetName'))]"
$integrationSubnetDependency = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('logicAppIntegrationSubnetName'))]"
$webIntegrationSubnetDependency = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('webAppIntegrationSubnetName'))]"
$parentSubnets = @($resources | Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets')
$peSubnet = @($parentSubnets | Where-Object name -Match "variables\('privateEndpointSubnetName'\)")[0]
$integrationSubnet = @($parentSubnets | Where-Object name -Match "variables\('logicAppIntegrationSubnetName'\)")[0]
$webIntegrationSubnet = @($parentSubnets | Where-Object name -Match "variables\('webAppIntegrationSubnetName'\)")[0]
$gatewaySubnet = @($parentSubnets | Where-Object name -Match "variables\('appGatewaySubnetName'\)")[0]
Assert-True ($gatewaySubnet.properties.networkSecurityGroup.id -eq "[resourceId('Microsoft.Network/networkSecurityGroups', variables('appGatewayNsgName'))]") 'Gateway subnet attaches the Front Door-only NSG'
Assert-True ($peSubnet.properties.privateEndpointNetworkPolicies -eq 'NetworkSecurityGroupEnabled') 'NSG enforcement enabled on private endpoints without changing route-table policies'
$webAsgs = @($resources | Where-Object type -eq 'Microsoft.Network/applicationSecurityGroups')
Assert-True ($webAsgs.Count -eq 1 -and $webPe[0].properties.applicationSecurityGroups.Count -eq 1) 'Web private endpoint belongs to one dedicated ASG'
$webAsgId = $webPe[0].properties.applicationSecurityGroups[0].id
Assert-True ($webAsgs[0].name -match 'azwasg' -and $webAsgId -match "Microsoft.Network/applicationSecurityGroups.*azwasg") 'Private endpoint references the web-only ASG'
$peNsg = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Network/networkSecurityGroups' -and $_.name -match 'azpensg'
})[0]
Assert-True ($peSubnet.properties.networkSecurityGroup.id -match "Microsoft.Network/networkSecurityGroups.*azpensg") 'Private endpoint subnet attaches the filtering NSG'
$peRules = @($peNsg.properties.securityRules | Sort-Object { $_.properties.priority })
Assert-True ($peRules.Count -eq 2) 'No private endpoint allow-list exceptions'
foreach ($rule in $peRules) {
    Assert-True ($rule.properties.direction -eq 'Inbound' -and $rule.properties.sourcePortRange -eq '*' -and
        $rule.properties.destinationApplicationSecurityGroups.Count -eq 1 -and
        $rule.properties.destinationApplicationSecurityGroups[0].id -eq $webAsgId -and
        -not $rule.properties.ContainsKey('destinationAddressPrefix')) 'Endpoint rules target only the web app, not Logic App, SQL, or storage'
}
Assert-True ($peRules[0].properties.access -eq 'Allow' -and $peRules[0].properties.protocol -eq 'Tcp' -and
    $peRules[0].properties.sourceAddressPrefix -eq "[parameters('appGatewaySubnetPrefix')]" -and
    $peRules[0].properties.destinationPortRange -eq '443') 'Only gateway instances and their health probes can reach web app HTTPS'
Assert-True ($peRules[1].properties.access -eq 'Deny' -and $peRules[1].properties.protocol -eq '*' -and
    $peRules[1].properties.sourceAddressPrefix -eq '*' -and $peRules[1].properties.destinationPortRange -eq '*' -and
    $peRules[1].properties.priority -lt 65000) 'Other private clients, including SCM clients, are denied before default VNet allow'
Assert-True ($gateway.properties.backendAddressPools[0].properties.backendAddresses.Count -eq 1 -and
    $gateway.properties.backendHttpSettingsCollection[0].properties.pickHostNameFromBackendAddress -eq $true) 'Gateway cannot forward arbitrary Host headers to SCM or other apps'
Assert-True ($parentSubnets.Count -eq 4) 'Four application subnets'
Assert-True ($peSubnet.dependsOn -contains $appGatewaySubnetDependency) 'Private endpoint subnet waits for gateway subnet'
Assert-True ($integrationSubnet.dependsOn -contains $privateEndpointSubnetDependency) 'Integration subnet waits for private endpoint subnet'
Assert-True ($webIntegrationSubnet.dependsOn -contains $integrationSubnetDependency) 'Web integration subnet waits for Logic App integration subnet'
Assert-True ($networkModule.dependsOn -contains $webIntegrationSubnetDependency) 'DC network waits for all application subnet writes'
Assert-True ($webIntegrationSubnet.properties.delegations[0].properties.serviceName -eq 'Microsoft.Web/serverFarms') 'Web integration subnet delegated to App Service'
Assert-True ($workload.parameters.webAppIntegrationSubnetPrefix.defaultValue -eq '10.42.5.0/24') 'Web integration subnet does not overlap existing subnet defaults'
$networkSubnets = @($network.resources | Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets')
$bastionSubnet = @($networkSubnets | Where-Object name -Match 'AzureBastionSubnet')[0]
Assert-True ($networkSubnets.Count -eq 2) 'DC and Bastion subnets only'
Assert-True ($bastionSubnet.dependsOn -contains "[resourceId('Microsoft.Network/virtualNetworks/subnets', parameters('vnetName'), 'DomainControllerSubnet')]") 'Bastion subnet waits for DC subnet'
Assert-True (@($network.resources | Where-Object type -In @(
    'Microsoft.Network/privateEndpoints', 'Microsoft.Network/networkInterfaces',
    'Microsoft.Network/bastionHosts', 'Microsoft.Network/applicationGateways', 'Microsoft.Web/sites'
)).Count -eq 0) 'No subnet consumers inside network provisioning barrier'

$privateEndpoints = @($resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints')
Assert-True ($privateEndpoints.Count -eq 4) 'Storage endpoint loop, SQL endpoint, and both app endpoints covered'
foreach ($endpoint in $privateEndpoints | Where-Object { $_.name -ne $webPe[0].name }) {
    Assert-True (-not $endpoint.properties.ContainsKey('applicationSecurityGroups')) "Unrelated private endpoint excluded from web-only restrictions: $($endpoint.name)"
}
foreach ($consumer in @($privateEndpoints) + @($logic, $web, $gateway)) {
    Assert-True ($consumer.dependsOn -contains $networkDependency) "Subnet consumer waits for all subnet writes: $($consumer.name)"
}
$dcModule = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'domain-controller' })[0]
Assert-True ($dcModule.dependsOn -contains $networkDependency) 'VM/Bastion module waits for all subnet writes'
foreach ($parameter in @('dcSubnetId', 'bastionSubnetId', 'privateIpAddress')) {
    Assert-True ($dcModule.properties.parameters[$parameter].value -match "'domain-controller-network'") "DC network configuration comes from completed module: $parameter"
}
$dc = $dcModule.properties.template
Assert-True (@($dc.resources | Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets').Count -eq 0) 'No subnet writes in VM/Bastion consumer module'
$vm = @($dc.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines')[0]
$nic = @($dc.resources | Where-Object type -eq 'Microsoft.Network/networkInterfaces')[0]
$extension = @($dc.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines/extensions')[0]
Assert-True ($dc.parameters.domainName.defaultValue -eq 'ad.demo.test') 'Correct forest default'
Assert-True ($vm.properties.storageProfile.imageReference.sku -eq '2022-datacenter-g2') 'Windows Server GUI image'
Assert-True ($vm.properties.storageProfile.dataDisks[0].caching -eq 'None') 'Uncached AD data disk'
Assert-True (-not $nic.properties.ipConfigurations[0].properties.ContainsKey('publicIPAddress')) 'No VM public IP'
Assert-True ($nic.properties.ipConfigurations[0].properties.privateIPAllocationMethod -eq 'Static') 'Static DC IP'
Assert-True ($extension.properties.ContainsKey('protectedSettings') -and -not $extension.properties.ContainsKey('settings')) 'Protected bootstrap settings only'
Assert-True (@($dc.resources | Where-Object type -eq 'Microsoft.Network/bastionHosts').Count -eq 1) 'Bastion provided'
Assert-True ($nic.properties.ipConfigurations[0].properties.subnet.id -eq "[parameters('dcSubnetId')]") 'NIC uses ready DC subnet'
$bastion = @($dc.resources | Where-Object type -eq 'Microsoft.Network/bastionHosts')[0]
Assert-True ($bastion.properties.ipConfigurations[0].properties.subnet.id -eq "[parameters('bastionSubnetId')]") 'Bastion uses ready subnet'
Assert-True (@($network.resources | Where-Object type -eq 'Microsoft.Network/natGateways').Count -eq 1) 'Explicit NAT egress'
$nsg = @($network.resources | Where-Object type -eq 'Microsoft.Network/networkSecurityGroups')[0]
Assert-True ($nsg.properties.securityRules[0].properties.sourceAddressPrefix -eq "[parameters('bastionSubnetPrefix')]") 'RDP restricted to Bastion'
Assert-True ($nsg.properties.securityRules[1].properties.access -eq 'Deny') 'Deny other DC inbound traffic'

$commandExpression = $extension.properties.protectedSettings.commandToExecute
Assert-True ($commandExpression -match "^\[format\('((?:''|[^'])*)',") 'Expected bootstrap command expression'
$commandFormat = $Matches[1].Replace("''", "'")
$script64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content (Join-Path $root 'scripts\Initialize-DemoForest.ps1') -Raw)))
$config64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"domainName":"ad.demo.test","netbiosName":"DEMO","dsrmPassword":"MockOnly-NotARealPassword!"}'))
$command = $commandFormat -f $script64, $config64
Assert-True ($command.Length -le 8191) 'Bootstrap fits Windows command-line length'
$commandBody = $command.Substring($command.IndexOf('-Command "') + 10).TrimEnd('"')
$tokens = $null
$errors = $null
[void] [System.Management.Automation.Language.Parser]::ParseInput($commandBody, [ref] $tokens, [ref] $errors)
Assert-True ($errors.Count -eq 0) 'Rendered bootstrap command quoting'

$verify = Get-TestScript 'Test-EntraObjectGuidExtension.ps1'
$tenant = [guid] '11111111-1111-1111-1111-111111111111'
$guid = [guid] '01234567-89ab-cdef-0123-456789abcdef'
$extensionName = 'extension_22222222222222222222222222222222_objectGUID'

& {
    function Get-MgContext { @{ TenantId = $tenant.ToString() } }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $Body, $ContentType)
        if ($scenario -eq 'graph-error') { throw 'Graph access denied.' }
        if ($Uri -match '/applications\?') {
            if ($scenario -eq 'missing-app') { return @{ value = @() } }
            return @{ value = @(@{ id = '22222222-2222-2222-2222-222222222222' }) }
        }
        if ($Uri -match '/extensionProperties$' -or $Uri -eq 'https://graph.microsoft.com/v1.0/mock-next-page') {
            if ($scenario -eq 'pagination' -and $Uri -match '/extensionProperties$') {
                return @{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/mock-next-page' }
            }
            if ($scenario -eq 'missing-definition') { return @{ value = @() } }
            $property = @{
                name = $extensionName
                isSyncedFromOnPremises = $true
                targetObjects = @('User')
            }
            if ($scenario -eq 'ambiguous-definition') { return @{ value = @($property, $property) } }
            return @{ value = @($property) }
        }
        Assert-True ($Uri -match '\?\$select=.*extension_') 'Explicit Graph extension selection'
        $user = @{ userPrincipalName = 'demo@example.com'; onPremisesSyncEnabled = $true }
        if ($scenario -eq 'unsynced') { $user.onPremisesSyncEnabled = $false }
        if ($scenario -ne 'missing-value') {
            $user[$extensionName] = if ($scenario -eq 'wrong-guid') { 'AAAAAAAAAAAAAAAAAAAAAA==' } else { [Convert]::ToBase64String($guid.ToByteArray()) }
        }
        return $user
    }
    foreach ($scenario in @('match', 'pagination')) {
        $result = & $verify -TenantId $tenant -UserId 'demo@example.com' -ExpectedObjectGuid $guid
        Assert-True ($result.Verified -and $result.ObjectGuid -eq $guid) "Exact GUID match: $scenario"
    }
    foreach ($case in @(
        @('missing-app', 'Tenant Schema Extension App; found 0'),
        @('graph-error', 'Graph access denied'),
        @('missing-definition', 'found 0'),
        @('ambiguous-definition', 'found 2'),
        @('missing-value', 'no value'),
        @('unsynced', 'not synchronized'),
        @('wrong-guid', 'does not match')
    )) {
        $scenario = $case[0]
        Assert-Throws { & $verify -TenantId $tenant -UserId 'demo@example.com' -ExpectedObjectGuid $guid } $case[1]
    }
    Assert-Throws { & $verify -TenantId '33333333-3333-3333-3333-333333333333' -UserId 'demo@example.com' -ExpectedObjectGuid $guid } 'intended tenant'
}

$bootstrap = Get-TestScript 'Initialize-DemoForest.ps1'
& {
    function Get-CimInstance {
        @{
            DomainRole = if ($scenario -in @('existing-dc', 'wrong-forest')) { 5 } else { 2 }
            Domain = if ($scenario -eq 'wrong-forest') { 'another.test' } else { 'ad.demo.test' }
            PartOfDomain = $scenario -eq 'member'
        }
    }
    function Test-Path { $scenario -eq 'pending-reboot' }
    function Get-Disk { @() }
    function Install-WindowsFeature { throw 'Unexpected attempt to install a real Windows feature.' }
    $config = @{
        domainName = 'ad.demo.test'
        netbiosName = 'DEMO'
        dsrmPassword = 'MockOnly-NotARealPassword!'
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json)))
    $scenario = 'existing-dc'
    $result = & $bootstrap -ConfigurationBase64 $encoded
    Assert-True ($result -match 'already exists') 'Bootstrap is idempotent on the correct DC'
    foreach ($case in @(
        @('wrong-forest', 'already a domain controller'),
        @('member', 'domain-joined'),
        @('pending-reboot', 'Restart the VM'),
        @('no-disk', 'exactly one')
    )) {
        $scenario = $case[0]
        Assert-Throws { & $bootstrap -ConfigurationBase64 $encoded } $case[1]
    }
    $config.domainName = "unsafe';command"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json)))
    Assert-Throws { & $bootstrap -ConfigurationBase64 $encoded } 'valid multi-label DNS'
}

& {
    $state = @{ formatted = $false; promoted = $false }
    function Get-CimInstance { @{ DomainRole = 2; Domain = 'WORKGROUP'; PartOfDomain = $false } }
    function Test-Path { $false }
    function Get-Disk {
        [pscustomobject] @{ Location = 'Integrated : Adapter 2 : Port 0 : Target 0 : LUN 0'; IsBoot = $false; IsSystem = $false; PartitionStyle = 'RAW'; Number = 2 }
    }
    function Get-Volume {
        if ($scenario -eq 'occupied-drive') { [pscustomobject] @{ DriveLetter = 'F'; FileSystemLabel = 'UserData' } }
    }
    function Initialize-Disk {
        param([Parameter(ValueFromPipeline)] $InputObject, $PartitionStyle, [switch] $PassThru)
        process { $InputObject }
    }
    function New-Partition {
        param([Parameter(ValueFromPipeline)] $InputObject, [switch] $UseMaximumSize, $DriveLetter)
        process { $InputObject }
    }
    function Format-Volume {
        param([Parameter(ValueFromPipeline)] $InputObject, $FileSystem, $NewFileSystemLabel, [switch] $Confirm)
        process { $state.formatted = $true }
    }
    function Install-WindowsFeature {
        param($Name, [switch] $IncludeManagementTools)
        @{ Success = $scenario -ne 'feature-failure'; RestartNeeded = 'No' }
    }
    function Import-Module { param($Name) }
    function Install-ADDSForest {
        param($DomainName, $DomainNetbiosName, [switch] $InstallDns, [switch] $CreateDnsDelegation,
            $DatabasePath, $LogPath, $SysvolPath, $SafeModeAdministratorPassword,
            [switch] $NoRebootOnCompletion, [switch] $Force)
        Assert-True ($DomainName -eq 'ad.demo.test' -and $DomainNetbiosName -eq 'DEMO') 'Promotion uses chosen forest'
        Assert-True ($DatabasePath -eq 'F:\NTDS' -and $LogPath -eq 'F:\NTDS' -and $SysvolPath -eq 'F:\SYSVOL') 'AD data paths'
        Assert-True ($SafeModeAdministratorPassword -is [securestring]) 'DSRM converted to secure string'
        Assert-True ($NoRebootOnCompletion.IsPresent) 'No reboot from inside extension'
        $state.promoted = $true
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{
        domainName = 'ad.demo.test'; netbiosName = 'DEMO'; dsrmPassword = 'MockOnly-NotARealPassword!'
    } | ConvertTo-Json)))
    $scenario = 'occupied-drive'
    Assert-Throws { & $bootstrap -ConfigurationBase64 $encoded } 'already in use'
    Assert-True (-not $state.formatted -and -not $state.promoted) 'Occupied volume is not touched'
    $scenario = 'feature-failure'
    Assert-Throws { & $bootstrap -ConfigurationBase64 $encoded } 'feature installation'
    Assert-True (-not $state.promoted) 'Failed feature installation does not promote'
    $scenario = 'success'
    & $bootstrap -ConfigurationBase64 $encoded | Out-Null
    Assert-True ($state.formatted -and $state.promoted) 'New disk initialization and forest promotion'
}

$configure = Get-TestScript 'Configure-DemoDirectory.ps1'
& {
    $state = @{ suffixAdded = $false; ouCreated = $false; dnsConfigured = $false }
    function Get-CimInstance { @{ DomainRole = 5; Domain = 'ad.demo.test' } }
    function Set-DnsServerForwarder {
        param($IPAddress)
        Assert-True ($IPAddress -eq '168.63.129.16') 'Azure DNS forwarding'
    }
    function Get-NetIPAddress {
        param($AddressFamily)
        [pscustomobject] @{ IPAddress = '10.42.3.4'; InterfaceIndex = 7 }
    }
    function Set-DnsClientServerAddress {
        param($InterfaceIndex, $ServerAddresses)
        Assert-True ($InterfaceIndex -eq 7 -and $ServerAddresses -eq '127.0.0.1') 'DC uses its own DNS'
        $state.dnsConfigured = $true
    }
    function Resolve-DnsName { param($Name, $Type, $Server, $ErrorAction) }
    function Get-ADForest {
        @{ Name = 'ad.demo.test'; UPNSuffixes = if ($scenario -eq 'existing') { @('verified.contoso.com') } else { @() } }
    }
    function Set-ADForest { param($Identity, $UPNSuffixes) $state.suffixAdded = $true }
    function Get-ADDomain { @{ DistinguishedName = 'DC=ad,DC=demo,DC=test' } }
    function Get-ADOrganizationalUnit {
        param($Filter, $SearchBase, $SearchScope)
        if ($scenario -eq 'existing') { @{ Name = 'SyncedDemoUsers' } }
    }
    function New-ADOrganizationalUnit {
        param($Name, $Path, $ProtectedFromAccidentalDeletion)
        Assert-True ($Name -eq 'SyncedDemoUsers' -and $ProtectedFromAccidentalDeletion) 'Scoped protected OU'
        $state.ouCreated = $true
    }
    Assert-Throws { & $configure -VerifiedUpnSuffix 'ad.demo.test' } 'domain verified'
    $scenario = 'existing'
    & $configure -VerifiedUpnSuffix 'verified.contoso.com' | Out-Null
    Assert-True (-not $state.suffixAdded -and -not $state.ouCreated) 'Directory preparation is idempotent'
    $scenario = 'new'
    & $configure -VerifiedUpnSuffix 'verified.contoso.com' | Out-Null
    Assert-True ($state.suffixAdded -and $state.ouCreated -and $state.dnsConfigured) 'Directory preparation'
}

$sqlServer = @($resources | Where-Object type -eq 'Microsoft.Sql/servers')[0]
$sqlDatabase = @($resources | Where-Object type -eq 'Microsoft.Sql/servers/databases')[0]
Assert-True ($sqlServer.properties.publicNetworkAccess -eq 'Disabled') 'SQL has no public access'
Assert-True ($sqlServer.properties.minimalTlsVersion -eq '1.2') 'SQL requires TLS 1.2'
Assert-True ($sqlServer.properties.administrators.azureADOnlyAuthentication -eq $true) 'SQL accepts only Entra authentication'
Assert-True ($sqlServer.properties.administrators.sid -eq "[parameters('sqlAdminObjectId')]") 'Separate explicit SQL administrator'
Assert-True (-not $sqlServer.properties.ContainsKey('administratorLoginPassword')) 'No SQL password'
Assert-True (@($resources | Where-Object type -eq 'Microsoft.Sql/servers/firewallRules').Count -eq 0) 'No SQL public firewall exceptions'
Assert-True ($sqlDatabase.sku.name -eq 'Basic' -and $sqlDatabase.properties.maxSizeBytes -eq 2147483648) 'Demo database is Basic with a 2 GiB limit'
Assert-True ($web.identity.type -eq 'UserAssigned') 'Web app uses only a user-assigned identity'
$webIdentityId = "[format('{0}', resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('webAppIdentityName')))]"
Assert-True ($web.identity.userAssignedIdentities.ContainsKey($webIdentityId)) 'Dedicated web app identity assigned'
Assert-True (-not $logic.identity.userAssignedIdentities.ContainsKey($webIdentityId)) 'Logic App does not share SQL identity'
Assert-True ($web.properties.virtualNetworkSubnetId -eq $webIntegrationSubnetDependency) 'Web app outbound VNet integration wired'
Assert-True ($web.properties.virtualNetworkSubnetId -ne $logic.properties.virtualNetworkSubnetId) 'Separate integration subnets for separate plans'
$settings = @{}
foreach ($setting in $web.properties.siteConfig.appSettings) { $settings[$setting.name] = $setting.value }
Assert-True ($settings.AZURE_CLIENT_ID -match "webAppIdentityName.*clientId") 'Azure SDK identity selection uses client ID'
Assert-True ($settings.SQL_SERVER_FQDN -match 'fullyQualifiedDomainName') 'SQL server setting comes from the resource'
Assert-True ($settings.SQL_DATABASE_NAME -eq "[variables('sqlDatabaseName')]") 'SQL database setting wired'
$connections = @($web.properties.siteConfig.connectionStrings)
Assert-True ($connections.Count -eq 2 -and $connections.name -contains 'MicrosoftDataSqlClient' -and
    $connections.name -contains 'SystemDataSqlClient') 'Exactly two provider-specific SQL connection strings replace DefaultConnection'
$connection = @($connections | Where-Object name -eq 'MicrosoftDataSqlClient')[0]
Assert-True ($connection.type -eq 'SQLAzure') 'Microsoft.Data.SqlClient connection uses SQLAzure configuration'
Assert-True ($connection.connectionString -match 'Authentication=Active Directory Managed Identity;User Id=') 'SQL connection uses managed identity'
Assert-True ($connection.connectionString -match "webAppIdentityName.*clientId") 'SQL connection selects dedicated client ID'
Assert-True ($connection.connectionString -match 'Encrypt=True;TrustServerCertificate=False') 'SQL certificate validation enabled'
Assert-True ($connection.connectionString -match 'Connection Timeout=30;') 'Managed identity connection retains bounded timeout'
Assert-True ($connection.connectionString -notmatch '(?i)Password=|AccountKey=') 'No connection string credentials'
$systemConnection = @($connections | Where-Object name -eq 'SystemDataSqlClient')[0]
Assert-True ($systemConnection.type -eq 'SQLAzure') 'System.Data.SqlClient connection uses SQLAzure configuration'
$sqlServerExpression = $settings.SQL_SERVER_FQDN.Trim('[]'.ToCharArray())
$sqlDatabaseExpression = $settings.SQL_DATABASE_NAME.Trim('[]'.ToCharArray())
$expectedSystemConnection = "[format('Server=tcp:{0},1433;Database={1};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;', $sqlServerExpression, $sqlDatabaseExpression)]"
Assert-True ($systemConnection.connectionString -eq $expectedSystemConnection) 'Legacy connection uses the configured SQL target, TLS and timeout without authentication keywords or credentials'
Assert-True ($connection.connectionString.Contains($sqlServerExpression) -and
    $connection.connectionString.Contains($sqlDatabaseExpression)) 'Both providers use the same SQL server and database'
$sqlPe = @($privateEndpoints | Where-Object { $_.properties.privateLinkServiceConnections[0].properties.groupIds[0] -eq 'sqlServer' })
Assert-True ($sqlPe.Count -eq 1) 'Exactly one SQL private endpoint'
Assert-True ($sqlPe[0].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId -match "variables\('sqlServerName'\)") 'SQL private endpoint targets server'
$sqlZone = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateDnsZones' -and $_.name -match 'sqlServerHostname' })
Assert-True ($sqlZone.Count -eq 1 -and $sqlZone[0].name -match 'privatelink') 'SQL private DNS uses cloud-specific suffix'
$sqlLink = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' -and $_.name -match 'sqlServerHostname' })[0]
Assert-True ($sqlLink.properties.virtualNetwork.id -match "variables\('vnetName'\)") 'SQL private DNS linked to application VNet'
$sqlZoneGroup = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' -and $_.properties.privateDnsZoneConfigs[0].name -eq 'sql' })[0]
Assert-True ($sqlZoneGroup.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -match 'sqlServerHostname') 'SQL endpoint DNS registration'
Assert-True (($web.dependsOn -join ' ') -match 'azdgsql') 'Web app waits for SQL DNS registration'
foreach ($parameter in @('sqlAdminObjectId', 'sqlAdminLogin', 'sqlAdminPrincipalType')) {
    Assert-True ($main.parameters.ContainsKey($parameter)) "SQL parameter exposed: $parameter"
    $deployment = @($main.resources | Where-Object type -eq 'Microsoft.Resources/deployments')[0]
    Assert-True ($deployment.properties.parameters[$parameter].value -eq "[parameters('$parameter')]") "SQL parameter forwarded: $parameter"
}
foreach ($output in @('SQL_SERVER_FQDN', 'SQL_DATABASE_NAME', 'SQL_TENANT_ID',
    'WEB_APP_IDENTITY_NAME', 'WEB_APP_IDENTITY_CLIENT_ID', 'WEB_APP_IDENTITY_PRINCIPAL_ID')) {
    Assert-True ($main.outputs.ContainsKey($output) -and $workload.outputs.ContainsKey($output)) "SQL setup output exposed: $output"
}

$initializeSql = Get-TestScript 'Initialize-WebAppDatabase.ps1'
& {
    $state = @{ calls = 0 }
    $parameters = @{
        ServerFqdn = 'demo.database.windows.net'
        DatabaseName = 'appdb'
        IdentityName = 'azwidtest'
        IdentityPrincipalId = $guid
        TenantId = $tenant
    }
    function Get-AzContext {
        if ($scenario -eq 'no-context') { return $null }
        @{ Tenant = @{ Id = if ($scenario -eq 'wrong-tenant') { '33333333-3333-3333-3333-333333333333' } else { $tenant.ToString() } } }
    }
    function Get-AzAccessToken {
        param($ResourceTypeName, $TenantId)
        Assert-True ($ResourceTypeName -eq 'SqlDB' -and $TenantId -eq $tenant.ToString()) 'SQL token audience and tenant'
        if ($scenario -eq 'token-error') { throw 'Token acquisition failed.' }
        @{ Token = ConvertTo-SecureString 'mock-token' -AsPlainText -Force }
    }
    function Invoke-Sqlcmd {
        param($ServerInstance, $Database, $AccessToken, $Query, $Encrypt,
            $ConnectionTimeout, $QueryTimeout, [switch] $AbortOnError,
            [switch] $DisableVariables, [switch] $DisableCommands, $ErrorAction)
        $state.calls++
        Assert-True ($ServerInstance -eq 'tcp:demo.database.windows.net,1433' -and $Database -eq 'appdb') 'Connect to application DB, not master'
        Assert-True ($AccessToken -is [securestring]) 'Token remains secure'
        Assert-True ($Encrypt -eq 'Mandatory' -and $AbortOnError -and $DisableVariables -and $DisableCommands) 'TLS, fail-fast, and SQLCMD command/variable expansion disabled'
        Assert-True ($ConnectionTimeout -eq 30 -and $QueryTimeout -eq 60) 'Bounded SQL timeouts'
        Assert-True ($Query -match 'SID = 0x67452301AB89EFCD0123456789ABCDEF, TYPE = E') 'Exact principal GUID byte order for SQL SID'
        Assert-True ($Query -match "IF DATABASE_PRINCIPAL_ID\(N'azwidtest'\) IS NULL") 'User creation is idempotent'
        Assert-True ($Query -match "name = N'azwidtest' AND sid = 0x.*AND type = 'E'") 'Existing principal identity/type checked before grants'
        Assert-True ($Query -match 'THROW 50001' -and $Query -match 'ROLLBACK TRANSACTION') 'Identity mismatch fails and rolls back'
        Assert-True (([regex]::Matches($Query, 'IF NOT EXISTS')).Count -eq 3) 'Principal guard and idempotent membership guards'
        Assert-True (([regex]::Matches($Query, 'ALTER ROLE')).Count -eq 2) 'Only two role grants'
        Assert-True ($Query -match 'ALTER ROLE db_datareader ADD MEMBER' -and $Query -match 'ALTER ROLE db_datawriter ADD MEMBER') 'Read/write grants'
        Assert-True ($Query -notmatch 'db_owner|db_ddladmin|GRANT CONTROL|CREATE TABLE') 'No administrative or schema grants'
        if ($scenario -eq 'sql-error') { throw 'SQL access denied.' }
        if ($scenario -eq 'no-result') { return }
        [pscustomobject] @{
            PrincipalId = if ($scenario -eq 'wrong-principal') { [guid]::Empty } else { $guid }
            CanRead = 1
            CanWrite = if ($scenario -eq 'missing-role') { 0 } else { 1 }
        }
    }
    $scenario = 'success'
    foreach ($attempt in 1..2) {
        $result = & $initializeSql @parameters
        Assert-True ($result.Verified -and $result.PrincipalId -eq $guid) "SQL setup verified, run $attempt"
    }
    foreach ($case in @(
        @('no-context', 'intended tenant'), @('wrong-tenant', 'intended tenant'),
        @('token-error', 'Token acquisition failed'), @('sql-error', 'SQL access denied'),
        @('no-result', 'verification failed'), @('wrong-principal', 'verification failed'),
        @('missing-role', 'verification failed')
    )) {
        $scenario = $case[0]
        Assert-Throws { & $initializeSql @parameters } $case[1]
    }
    $scenario = 'success'
    $callsBeforeInvalidInput = $state.calls
    $invalid = $parameters.Clone()
    $invalid.DatabaseName = 'master'
    Assert-Throws { & $initializeSql @invalid } 'system database'
    $invalid = $parameters.Clone()
    $invalid.IdentityPrincipalId = [guid]::Empty
    Assert-Throws { & $initializeSql @invalid } 'non-empty GUIDs'
    $invalid = $parameters.Clone()
    $invalid.IdentityName = "unsafe']; DROP USER x;--"
    Assert-Throws { & $initializeSql @invalid } 'does not match'
    Assert-True ($state.calls -eq $callsBeforeInvalidInput) 'Invalid inputs never reach SQL'
}

Write-Output "Passed $checks checks: infrastructure and restricted Front Door ingress contracts, script syntax, mocked SQL setup, extension verification, forest bootstrap, and directory preparation. No Azure or tenant changes made."
