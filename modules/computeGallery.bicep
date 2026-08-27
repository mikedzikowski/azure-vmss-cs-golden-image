// =============================================================================
// Azure Compute Gallery Module
// =============================================================================
// Creates Azure Compute Gallery and image definition for CrowdStrike golden images
// =============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Resource name prefix')
param namePrefix string

@description('Location for all resources')
param location string

@description('Tags to apply to all resources')
param tags object

@description('Azure Compute Gallery name')
param galleryName string

@description('Image definition name')
param imageDefinitionName string

@description('Source image publisher')
param sourceImagePublisher string

@description('Source image offer')
param sourceImageOffer string

@description('Source image SKU')
param sourceImageSku string

// =============================================================================
// VARIABLES
// =============================================================================

var sanitizedGalleryName = replace(replace(galleryName, '_', ''), '-', '')

// =============================================================================
// AZURE COMPUTE GALLERY
// =============================================================================

resource computeGallery 'Microsoft.Compute/galleries@2023-07-03' = {
  name: sanitizedGalleryName
  location: location
  tags: tags
  properties: {
    description: 'Azure Compute Gallery for CrowdStrike Falcon golden images'
    identifier: {}
  }
}

// =============================================================================
// IMAGE DEFINITION
// =============================================================================

resource imageDefinition 'Microsoft.Compute/galleries/images@2023-07-03' = {
  parent: computeGallery
  name: imageDefinitionName
  location: location
  tags: tags
  properties: {
    description: 'Windows Server golden image with the CrowdStrike Falcon sensor pre-installed'
    osType: 'Windows'
    osState: 'Generalized'
    identifier: {
      publisher: 'CrowdStrike'
      offer: 'FalconGoldenImage'
      // Use the (OS-derived) definition name so each OS gets a unique publisher/offer/sku
      // triple within the gallery. The identifier is immutable and must be unique per definition.
      sku: imageDefinitionName
    }
    recommended: {
      vCPUs: {
        min: 2
        max: 64
      }
      memory: {
        min: 4
        max: 256
      }
    }
    hyperVGeneration: 'V2'
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunch'
      }
    ]
    architecture: 'x64'
    // Define source image reference for AIB
    disallowed: {
      diskTypes: []
    }
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Azure Compute Gallery resource ID')
output galleryId string = computeGallery.id

@description('Azure Compute Gallery name')
output galleryName string = computeGallery.name

@description('Image definition resource ID')
output imageDefinitionId string = imageDefinition.id

@description('Image definition name')
output imageDefinitionName string = imageDefinition.name