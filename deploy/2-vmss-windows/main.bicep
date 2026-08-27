// =============================================================================
// STEP 2 - Deploy a VMSS from the CrowdStrike Falcon golden image
// =============================================================================
// Deploys networking (VNet/Subnet/NSG + load balancer) and a Flexible-orchestration
// VMSS created from the golden image published in Step 1. The sensor is already baked
// into the image (installed with NO_START=1), so each instance auto-starts the sensor
// and registers its own unique AID on first boot - no runtime script required.
//
// This is the "Deploy to Azure" (button 2) entry point. It is compiled to
// deploy/2-vmss-windows/azuredeploy.json.
// =============================================================================

targetScope = 'resourceGroup'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Environment name used in resource naming.')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Project/workload name used in resource naming.')
param projectName string = 'crowdstrike'

@description('VM size for the scale set.')
param vmSku string = 'Standard_D2s_v3'

@description('Number of VM instances.')
@minValue(1)
@maxValue(100)
param instanceCount int = 2

@description('Local administrator username.')
param adminUsername string = 'azureuser'

@description('Local administrator password.')
@secure()
param adminPassword string

@description('Full resource ID of the gallery image DEFINITION from Step 1 (shown in Step 1 outputs as imageDefinitionId, or selected via the image picker).')
param imageDefinitionId string

@description('Image version to deploy. Use "latest" for the newest published version, or an exact version like 1.0.0 / 20348.x.x.')
param imageVersion string = 'latest'

@description('Virtual network address prefix.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix.')
param subnetAddressPrefix string = '10.0.1.0/24'

@description('Optional RDP source IP ranges (CIDR). Leave empty to add no inbound RDP rule.')
param rdpSourceIpRanges array = []

var namePrefix = '${projectName}-${environment}'
var resourceTags = {
  Environment: environment
  Project: projectName
  Purpose: 'CrowdStrike-Falcon-VMSS'
  ManagedBy: 'Bicep'
}

module networking '../../modules/networking.bicep' = {
  name: 'networking-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    tags: resourceTags
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    rdpSourceIpRanges: rdpSourceIpRanges
  }
}

module vmss '../../modules/vmss.bicep' = {
  name: 'vmss-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    tags: resourceTags
    vmSku: vmSku
    instanceCount: instanceCount
    adminUsername: adminUsername
    adminPassword: adminPassword
    imageDefinitionId: imageDefinitionId
    imageVersion: imageVersion
    subnetId: networking.outputs.subnetId
  }
}

@description('VMSS resource ID.')
output vmssId string = vmss.outputs.vmssId

@description('VMSS name.')
output vmssName string = vmss.outputs.vmssName

@description('Load balancer public IP.')
output loadBalancerPublicIp string = vmss.outputs.loadBalancerPublicIp
