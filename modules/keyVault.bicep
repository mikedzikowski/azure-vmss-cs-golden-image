// =============================================================================
// Key Vault Module - creates an RBAC Key Vault and seeds CrowdStrike secrets
// =============================================================================
// Secrets are passed in as @secure() parameters and written as ARM child resources
// (a management-plane operation - the deployer's Contributor/Owner rights are enough;
// no data-plane role is needed to WRITE them here). The Azure Image Builder identity
// is granted Key Vault Secrets User separately (in the imageBuilder module) so it can
// READ them at build time via the data plane.
// =============================================================================

targetScope = 'resourceGroup'

@description('Key Vault name (3-24 alphanumeric/hyphen, must start with a letter).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Location for the Key Vault.')
param location string

@description('Tags to apply.')
param tags object

@description('CrowdStrike Falcon OAuth2 API client id.')
@secure()
param falconClientId string

@description('CrowdStrike Falcon OAuth2 API client secret.')
@secure()
param falconClientSecret string

@description('CrowdStrike Falcon cloud region (us-1, us-2, eu-1, us-gov-1). Not a secret, but stored in Key Vault so the build reads all config from one place.')
param falconCloud string = 'us-1'

@description('Optional: Windows Sensor Update Policy name that resolves the sensor version to install. Leave empty to use platform_default.')
param sensorUpdatePolicyName string = ''

@description('Optional: CrowdStrike provisioning token.')
@secure()
param provToken string = ''

// RBAC-authorization Key Vault. enabledForTemplateDeployment is not required for the
// AIB data-plane read pattern used here.
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource secretClientId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'crowdstrike-client-id'
  properties: {
    value: falconClientId
  }
}

resource secretClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'crowdstrike-client-secret'
  properties: {
    value: falconClientSecret
  }
}

resource secretFalconCloud 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'crowdstrike-falcon-cloud'
  properties: {
    value: falconCloud
  }
}

// Optional secrets - only created when a value is supplied.
resource secretSensorPolicy 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(sensorUpdatePolicyName)) {
  parent: keyVault
  name: 'crowdstrike-sensor-update-policy'
  properties: {
    value: sensorUpdatePolicyName
  }
}

resource secretProvToken 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(provToken)) {
  parent: keyVault
  name: 'crowdstrike-prov-token'
  properties: {
    value: provToken
  }
}

@description('Key Vault name.')
output keyVaultName string = keyVault.name

@description('Key Vault resource ID.')
output keyVaultId string = keyVault.id
