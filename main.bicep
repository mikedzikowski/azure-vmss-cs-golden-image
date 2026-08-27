// =============================================================================
// CrowdStrike Falcon Golden Image VMSS Deployment - Main Template
// =============================================================================
// This template orchestrates the complete deployment of CrowdStrike Falcon
// using a Golden Image approach with Azure Image Builder and VMSS
// =============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Location for all resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Environment name (dev, test, prod)')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Project or workload name for resource naming')
param projectName string = 'crowdstrike'

@description('Deployment mode - imageOnly builds golden image, vmssOnly deploys VMSS from existing image, complete does both')
@allowed(['imageOnly', 'vmssOnly', 'complete'])
param deploymentMode string = 'complete'

// Azure Compute Gallery Configuration
@description('Azure Compute Gallery name')
param galleryName string = '${projectName}_${environment}_${uniqueString(resourceGroup().id)}'

@description('Image definition name')
param imageDefinitionName string = 'CrowdStrike-Windows-2022'

@description('Image version to build (use semantic versioning)')
param imageVersion string = '1.0.0'

@description('Target image version for VMSS deployment (use "latest" for most recent)')
param targetImageVersion string = 'latest'

// Source Image Configuration
@description('Source Windows image publisher')
param sourceImagePublisher string = 'MicrosoftWindowsServer'

@description('Source Windows image offer')
param sourceImageOffer string = 'WindowsServer'

@description('Source Windows image SKU')
param sourceImageSku string = '2022-datacenter-g2'

@description('Source Windows image version')
param sourceImageVersion string = 'latest'

// VMSS Configuration (only used when deploymentMode is vmssOnly or complete)
@description('Virtual machine SKU size for VMSS')
@allowed(['Standard_B2s', 'Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_F2s_v2'])
param vmSku string = 'Standard_D2s_v3'

@description('Number of VM instances in the scale set')
@minValue(1)
@maxValue(100)
param instanceCount int = 2

@description('Admin username for the VMs')
param adminUsername string = 'azureuser'

@description('Admin password for Windows VMs')
@secure()
param adminPassword string

// CrowdStrike Configuration
@description('Azure Key Vault name containing CrowdStrike secrets')
param keyVaultName string

// Networking Configuration (only used for VMSS deployment)
@description('Virtual network address prefix')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix for VMSS')
param subnetAddressPrefix string = '10.0.1.0/24'

@description('Allow RDP access from these IP ranges (CIDR notation)')
param rdpSourceIpRanges array = []

// =============================================================================
// VARIABLES
// =============================================================================

var namePrefix = '${projectName}-${environment}'
var resourceTags = {
  Environment: environment
  Project: projectName
  Purpose: 'CrowdStrike-Falcon-VMSS'
  ManagedBy: 'Bicep'
  DeploymentMode: deploymentMode
}

// =============================================================================
// EXISTING RESOURCES
// =============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (deploymentMode == 'imageOnly' || deploymentMode == 'complete') {
  name: keyVaultName
}

// =============================================================================
// MODULE DEPLOYMENTS
// =============================================================================

// Deploy Azure Compute Gallery (always deploy for consistency)
module computeGallery 'modules/computeGallery.bicep' = {
  name: 'compute-gallery-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    tags: resourceTags
    galleryName: galleryName
    imageDefinitionName: imageDefinitionName
    sourceImagePublisher: sourceImagePublisher
    sourceImageOffer: sourceImageOffer
    sourceImageSku: sourceImageSku
  }
}

// Deploy Azure Image Builder (only when building images)
module imageBuilder 'modules/imageBuilder.bicep' = if (deploymentMode == 'imageOnly' || deploymentMode == 'complete') {
  name: 'image-builder-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    tags: resourceTags
    galleryName: galleryName
    imageDefinitionName: imageDefinitionName
    imageVersion: imageVersion
    sourceImagePublisher: sourceImagePublisher
    sourceImageOffer: sourceImageOffer
    sourceImageSku: sourceImageSku
    sourceImageVersion: sourceImageVersion
    keyVaultName: keyVaultName
  }
  dependsOn: [
    computeGallery
  ]
}

// Deploy networking infrastructure (only for VMSS deployment)
module networking 'modules/networking.bicep' = if (deploymentMode == 'vmssOnly' || deploymentMode == 'complete') {
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

// Deploy VMSS (only when deploying VMSS)
module vmss 'modules/vmss.bicep' = if (deploymentMode == 'vmssOnly' || deploymentMode == 'complete') {
  name: 'vmss-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    tags: resourceTags
    vmSku: vmSku
    instanceCount: instanceCount
    adminUsername: adminUsername
    adminPassword: adminPassword
    galleryName: galleryName
    imageDefinitionName: imageDefinitionName
    imageVersion: targetImageVersion
    subnetId: deploymentMode == 'vmssOnly' || deploymentMode == 'complete' ? networking.outputs.subnetId : ''
    keyVaultName: keyVaultName
  }
  dependsOn: [
    computeGallery
  ]
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Resource group name')
output resourceGroupName string = resourceGroup().name

@description('Azure Compute Gallery resource ID')
output galleryId string = computeGallery.outputs.galleryId

@description('Image definition resource ID')
output imageDefinitionId string = computeGallery.outputs.imageDefinitionId

@description('Image Builder template name (if deployed)')
output imageBuilderTemplateName string = deploymentMode == 'imageOnly' || deploymentMode == 'complete' ? imageBuilder.outputs.templateName : ''

@description('VMSS resource ID (if deployed)')
output vmssId string = deploymentMode == 'vmssOnly' || deploymentMode == 'complete' ? vmss.outputs.vmssId : ''

@description('VMSS name (if deployed)')
output vmssName string = deploymentMode == 'vmssOnly' || deploymentMode == 'complete' ? vmss.outputs.vmssName : ''

@description('Load balancer public IP (if deployed)')
output loadBalancerPublicIp string = deploymentMode == 'vmssOnly' || deploymentMode == 'complete' ? vmss.outputs.loadBalancerPublicIp : ''

@description('System-assigned managed identity principal ID (if deployed)')
output managedIdentityPrincipalId string = deploymentMode == 'vmssOnly' || deploymentMode == 'complete' ? vmss.outputs.managedIdentityPrincipalId : ''