// =============================================================================
// STEP 1 - CrowdStrike Falcon Golden Image (self-contained)
// =============================================================================
// Creates EVERYTHING needed to build the golden image:
//   - Key Vault (RBAC) seeded with the CrowdStrike secrets you pass in securely
//   - Azure Compute Gallery + image definition (Trusted Launch)
//   - Azure Image Builder template + managed identity + role assignments
// After this deploys, TRIGGER the image build (see README) to produce the image.
//
// "Deploy to Azure" button 1 entry point -> compiled to deploy/1-golden-image/azuredeploy.json
// =============================================================================

targetScope = 'resourceGroup'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Environment name used in resource naming.')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Project/workload name used in resource naming.')
param projectName string = 'crowdstrike'

// ---- Key Vault + CrowdStrike secrets (created and seeded by this deployment) ----

@description('Key Vault name to create (3-24 chars, start with a letter, alphanumeric/hyphen). Must be globally unique.')
@minLength(3)
@maxLength(24)
param keyVaultName string = take('kvcs${uniqueString(resourceGroup().id)}', 24)

@description('CrowdStrike Falcon OAuth2 API Client ID. Needs Sensor Download (read) + Sensor Update Policies (read).')
@secure()
param falconClientId string

@description('CrowdStrike Falcon OAuth2 API Client Secret.')
@secure()
param falconClientSecret string

@description('CrowdStrike Falcon cloud region.')
@allowed(['us-1', 'us-2', 'eu-1', 'us-gov-1'])
param falconCloud string = 'us-1'

@description('Optional: explicit CrowdStrike Customer ID (CID) with checksum. Leave empty to have the build retrieve the CCID automatically from the Falcon API.')
@secure()
param falconCid string = ''

@description('Optional: Windows Sensor Update Policy name that resolves the sensor version. Leave empty for platform_default.')
param sensorUpdatePolicyName string = ''

@description('Optional: CrowdStrike provisioning token.')
@secure()
param provToken string = ''

// ---- Gallery / image ----

@description('Azure Compute Gallery name (alphanumeric/underscore). Defaults to a name made unique per resource group, since gallery names must be unique in the subscription.')
param galleryName string = '${projectName}_${environment}_${uniqueString(resourceGroup().id)}'

@description('Image definition name.')
param imageDefinitionName string = 'CrowdStrike-Windows-2022'

@description('Semantic image version to build, e.g. 1.0.0.')
param imageVersion string = '1.0.0'

@description('Source image publisher.')
param sourceImagePublisher string = 'MicrosoftWindowsServer'

@description('Source image offer.')
param sourceImageOffer string = 'WindowsServer'

@description('Source image SKU (Gen2 / Trusted Launch capable).')
param sourceImageSku string = '2022-datacenter-g2'

@description('Source image version.')
param sourceImageVersion string = 'latest'

var namePrefix = '${projectName}-${environment}'
var resourceTags = {
  Environment: environment
  Project: projectName
  Purpose: 'CrowdStrike-Falcon-GoldenImage'
  ManagedBy: 'Bicep'
}

// Create + seed Key Vault with the CrowdStrike secrets (from secure params).
module keyVault '../../modules/keyVault.bicep' = {
  name: 'keyvault-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    tags: resourceTags
    falconClientId: falconClientId
    falconClientSecret: falconClientSecret
    falconCloud: falconCloud
    falconCid: falconCid
    sensorUpdatePolicyName: sensorUpdatePolicyName
    provToken: provToken
  }
}

module computeGallery '../../modules/computeGallery.bicep' = {
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

module imageBuilder '../../modules/imageBuilder.bicep' = {
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
    keyVault
    computeGallery
  ]
}

@description('Key Vault name that was created and seeded.')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Azure Compute Gallery name (pass this to Step 2 if deploying it to a different resource group).')
output galleryName string = computeGallery.outputs.galleryName

@description('Azure Compute Gallery resource ID.')
output galleryId string = computeGallery.outputs.galleryId

@description('Image definition resource ID.')
output imageDefinitionId string = computeGallery.outputs.imageDefinitionId

@description('Image Builder template name - run this to build the image (see README).')
output imageBuilderTemplateName string = imageBuilder.outputs.templateName
