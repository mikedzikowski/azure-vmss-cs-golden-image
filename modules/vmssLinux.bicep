// =============================================================================
// VMSS Module (LINUX) - CrowdStrike Golden Image
// =============================================================================
// Deploys a Flexible-orchestration VMSS from a Linux golden image with the CrowdStrike
// sensor pre-installed (CID baked, AID stripped). Each instance registers its own unique
// AID on first boot - no runtime script required.
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

@description('Virtual machine SKU size')
param vmSku string

@description('Number of VM instances')
param instanceCount int

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('Azure Compute Gallery name')
param galleryName string

@description('Image definition name')
param imageDefinitionName string

@description('Image version (use "latest" for most recent)')
param imageVersion string

@description('Subnet resource ID')
param subnetId string

@description('Key Vault name')
param keyVaultName string

@description('Platform fault domain count. Required for Flexible orchestration. 1 gives maximum spreading and broadest VM-size compatibility.')
param platformFaultDomainCount int = 1

// =============================================================================
// VARIABLES
// =============================================================================

var vmssName = '${namePrefix}-vmss'
var vmssIdentityName = '${namePrefix}-vmss-identity'
var loadBalancerName = '${namePrefix}-lb'
var publicIpName = '${namePrefix}-pip'
var backendPoolName = '${namePrefix}-backend-pool'

// Image reference id. Azure Compute Gallery resolves the image DEFINITION id (no version)
// to the newest version at deploy time; a specific version pins to it. So when
// imageVersion == 'latest' we omit the /versions/<v> segment.
var galleryImageBaseId = '${subscription().id}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Compute/galleries/${sanitizedGalleryName}/images/${imageDefinitionName}'
var galleryImageId = toLower(imageVersion) == 'latest' ? galleryImageBaseId : '${galleryImageBaseId}/versions/${imageVersion}'
var sanitizedGalleryName = replace(replace(galleryName, '_', ''), '-', '')

// =============================================================================
// PUBLIC IP FOR LOAD BALANCER
// =============================================================================

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower('${namePrefix}-${uniqueString(resourceGroup().id)}')
    }
  }
}

// =============================================================================
// LOAD BALANCER
// =============================================================================

resource loadBalancer 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: loadBalancerName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'loadBalancerFrontEnd'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
      }
    ]
    loadBalancingRules: [
      {
        name: 'HTTP'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, 'loadBalancerFrontEnd')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendPoolName)
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 5
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'tcpProbe')
          }
        }
      }
    ]
    probes: [
      {
        name: 'tcpProbe'
        properties: {
          protocol: 'Tcp'
          port: 80
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// =============================================================================
// VIRTUAL MACHINE SCALE SET (LINUX)
// =============================================================================

// User-assigned identity for the VMSS. Flexible orchestration does NOT support
// system-assigned managed identity (per Microsoft docs), so we use a user-assigned one.
resource vmssIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: vmssIdentityName
  location: location
  tags: tags
}

resource vmScaleSet 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmssName
  location: location
  tags: tags
  sku: {
    name: vmSku
    tier: 'Standard'
    capacity: instanceCount
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${vmssIdentity.id}': {}
    }
  }
  properties: {
    orchestrationMode: 'Flexible'
    // Flexible orchestration requirements (verified via Microsoft Learn):
    //  - platformFaultDomainCount is required
    //  - singlePlacementGroup must be false
    //  - upgradePolicy must be null/empty (removed)
    singlePlacementGroup: false
    platformFaultDomainCount: platformFaultDomainCount
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        imageReference: {
          id: galleryImageId
        }
      }
      // The gallery image definition is Trusted Launch (Gen2 source), so instances must
      // be created with a matching TrustedLaunch security profile (secure boot + vTPM).
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
      osProfile: {
        computerNamePrefix: toLower(take(namePrefix, 9))
        adminUsername: adminUsername
        adminPassword: adminPassword
        // Password auth is enabled to mirror the Windows path and the shared Step 2 form.
        // For production, prefer SSH keys (set disablePasswordAuthentication: true and
        // supply ssh.publicKeys).
        linuxConfiguration: {
          disablePasswordAuthentication: false
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'ImageDefault'
          }
        }
      }
      networkProfile: {
        // Flexible orchestration requires networkApiVersion 2021-11-01 or higher.
        networkApiVersion: '2022-11-01'
        networkInterfaceConfigurations: [
          {
            name: '${vmssName}-nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'internal'
                  properties: {
                    primary: true
                    subnet: {
                      id: subnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendPoolName)
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      // NOTE: No custom-script extension is used for CrowdStrike. The golden image already
      // has the sensor installed with the CID baked in and the AID stripped (golden image
      // prep). On a clone's first boot the falcon-sensor service starts and registers its
      // own unique AID - so no runtime CID injection is needed.
    }
  }
}

// =============================================================================
// ROLE ASSIGNMENT FOR KEY VAULT ACCESS
// =============================================================================

// Key Vault Secrets User role definition ID
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmssIdentity.id, keyVault.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: vmssIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('VMSS resource ID')
output vmssId string = vmScaleSet.id

@description('VMSS name')
output vmssName string = vmScaleSet.name

@description('VMSS managed identity principal ID')
output managedIdentityPrincipalId string = vmssIdentity.properties.principalId

@description('Load balancer public IP address')
output loadBalancerPublicIp string = publicIp.properties.ipAddress

@description('Load balancer FQDN')
output loadBalancerFqdn string = publicIp.properties.dnsSettings.fqdn
