// =============================================================================
// VMSS Module with CrowdStrike Golden Image and First Boot CID Injection
// =============================================================================
// Deploys VMSS using golden image with CrowdStrike sensor pre-installed
// Injects CID on first boot using Custom Script Extension
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

@description('Full resource ID of the gallery image DEFINITION to deploy (from Step 1 output / the image picker).')
param imageDefinitionId string

@description('Image version (use "latest" for most recent)')
param imageVersion string

@description('Subnet resource ID')
param subnetId string

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
// imageVersion == 'latest' we use the definition id directly.
var galleryImageId = toLower(imageVersion) == 'latest' ? imageDefinitionId : '${imageDefinitionId}/versions/${imageVersion}'


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
// VIRTUAL MACHINE SCALE SET
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
          diskSizeGB: 127
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
        computerNamePrefix: toLower(take(namePrefix, 9)) // Windows has 15 char limit, leave room for suffix
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'AutomaticByOS'
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
      // NOTE: No custom-script extension is used for CrowdStrike.
      // The golden image already has the sensor installed with the CID baked in and
      // NO_START=1 (which only suppresses sensor start during image build). On a clone's
      // first boot the CSFalconService starts automatically and registers its own unique
      // AID - so no runtime CID injection is needed. (The prior Linux-falconctl extension
      // was removed: it was wrong for Windows and unnecessary with a baked CID.)
    }
  }
  // The instances attach to the load balancer backend pool via a string resourceId (no
  // symbolic reference), so Bicep cannot infer the dependency. Make it explicit to avoid a
  // "load balancer not found" race during parallel creation.
  dependsOn: [
    loadBalancer
  ]
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('VMSS resource ID')
output vmssId string = vmScaleSet.id

@description('VMSS name')
output vmssName string = vmScaleSet.name

@description('System-assigned managed identity principal ID')
output managedIdentityPrincipalId string = vmssIdentity.properties.principalId

@description('Load balancer public IP address')
output loadBalancerPublicIp string = publicIp.properties.ipAddress

@description('Load balancer FQDN')
output loadBalancerFqdn string = publicIp.properties.dnsSettings.fqdn