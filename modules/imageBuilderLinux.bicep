// =============================================================================
// Azure Image Builder Module (LINUX)
// =============================================================================
// Creates an Azure Image Builder template for a CrowdStrike Falcon Linux golden image.
// CRITICAL: The vendor script is run with PREP_GOLDEN_IMAGE=true. That installs the
// sensor, registers it (which assigns an AID), then REMOVES the AID via
// `falconctl -d -f --aid` so the image ships with the CID baked in but NO AID. Each VM
// created from the image registers its own unique AID on first boot. This is the Linux
// analogue of the Windows NO_START=1 pattern.
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

@description('Image version to build')
param imageVersion string

@description('Source image publisher')
param sourceImagePublisher string

@description('Source image offer')
param sourceImageOffer string

@description('Source image SKU')
param sourceImageSku string

@description('Source image version')
param sourceImageVersion string

@description('Key Vault name containing CrowdStrike secrets')
param keyVaultName string

// =============================================================================
// VARIABLES
// =============================================================================

// Unique per (resource group + image definition), so different distros get distinct
// templates and re-running the same distro idempotently updates its own. The resolved
// name is surfaced via the templateName output (use it for the portal/CLI "Start build").
var aibTemplateName = '${namePrefix}-aib-template-${uniqueString(resourceGroup().id, imageDefinitionName)}'
var aibManagedIdentityName = '${namePrefix}-aib-identity'
var sanitizedGalleryName = replace(replace(galleryName, '_', ''), '-', '')

// AIB requires these specific role definitions
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
// Managed Identity Operator - REQUIRED so the AIB template identity can associate the
// build-VM identity onto the transient Packer build VM (verified against Microsoft Learn:
// image-builder-json#identity "User-assigned identity for the Image Builder Build VM").
var managedIdentityOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830'

// Shell script for CrowdStrike Falcon installation in a Linux golden image.
// CRITICAL: run LAST, with PREP_GOLDEN_IMAGE=true so the AID is stripped after registration.
// NOTE: this is a Bicep multi-line string which does NOT interpolate; the KEYVAULT_NAME
// placeholder is substituted via replace() below. Secrets are read from Key Vault at build
// time using the build VM's user-assigned managed identity (IMDS), never baked into the template.
var falconInstallScript = '''
#!/bin/bash
set -eu

echo "Starting CrowdStrike Falcon sensor golden image prep (Linux)..."
echo "PREP_GOLDEN_IMAGE=true -> sensor installs, registers, then the AID is removed for cloning"

KV_NAME="KEYVAULT_NAME"
KV_API="7.4"
IMDS_TOKEN_URL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"

# AIB Shell customizers run as a NON-root user (verified via Microsoft Learn image-builder-json:
# "Prefix the commands with sudo to run them with super user privileges"). Detect and elevate.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# Obtain a Key Vault access token from IMDS (build VM user-assigned identity). IMDS is
# reachable by any local user, so this does not need elevation.
echo "Requesting Key Vault access token from IMDS..."
TOKEN=$(curl -s -H "Metadata: true" "$IMDS_TOKEN_URL" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to obtain IMDS access token for Key Vault (is the build-VM identity attached?)" >&2
    exit 1
fi
echo "Obtained Key Vault access token."

# Read a secret value from Key Vault. Returns empty string if the secret is absent.
kv_secret() {
    resp=$(curl -s -H "Authorization: Bearer $TOKEN" "https://$KV_NAME.vault.azure.net/secrets/$1?api-version=$KV_API" || true)
    echo "$resp" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p'
}

echo "Reading CrowdStrike configuration from Key Vault..."
FALCON_CLIENT_ID_VAL=$(kv_secret crowdstrike-client-id)
FALCON_CLIENT_SECRET_VAL=$(kv_secret crowdstrike-client-secret)
FALCON_CLOUD_VAL=$(kv_secret crowdstrike-falcon-cloud)
POLICY_VAL=$(kv_secret crowdstrike-sensor-update-policy)
CID_VAL=$(kv_secret crowdstrike-cid)
PTOKEN_VAL=$(kv_secret crowdstrike-prov-token)

if [ -z "$FALCON_CLIENT_ID_VAL" ] || [ -z "$FALCON_CLIENT_SECRET_VAL" ]; then
    echo "ERROR: Could not read crowdstrike-client-id / crowdstrike-client-secret from Key Vault." >&2
    exit 1
fi
if [ -n "$POLICY_VAL" ]; then echo "Using sensor update policy: $POLICY_VAL"; fi
if [ -n "$CID_VAL" ]; then echo "Using explicitly provided CID."; fi
if [ -n "$PTOKEN_VAL" ]; then echo "Using provisioning token."; fi

echo "Downloading CrowdStrike Falcon Linux install script..."
SCRIPT_PATH="/tmp/falcon-linux-install.sh"
curl -sL "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/install/falcon-linux-install.sh" -o "$SCRIPT_PATH"
if [ ! -s "$SCRIPT_PATH" ]; then
    echo "ERROR: Failed to download the CrowdStrike Linux install script." >&2
    exit 1
fi
chmod +x "$SCRIPT_PATH"

echo "Installing CrowdStrike Falcon sensor (PREP_GOLDEN_IMAGE=true)..."
# Pass secrets to the elevated process via 'env' rather than relying on 'sudo -E' (which is
# blocked by the default env_reset sudoers policy). Empty optional values are treated as
# unset by the vendor script's -n/-z checks. Quoting preserves values that contain spaces
# (e.g. a policy name).
$SUDO env \
    FALCON_CLIENT_ID="$FALCON_CLIENT_ID_VAL" \
    FALCON_CLIENT_SECRET="$FALCON_CLIENT_SECRET_VAL" \
    FALCON_CLOUD="$FALCON_CLOUD_VAL" \
    FALCON_SENSOR_UPDATE_POLICY_NAME="$POLICY_VAL" \
    FALCON_CID="$CID_VAL" \
    FALCON_PROVISIONING_TOKEN="$PTOKEN_VAL" \
    PREP_GOLDEN_IMAGE="true" \
    bash "$SCRIPT_PATH"

echo "Verifying sensor installation..."
if [ ! -x /opt/CrowdStrike/falconctl ]; then
    echo "ERROR: /opt/CrowdStrike/falconctl not found after installation." >&2
    exit 1
fi

# The CID should be set; the AID should be empty (stripped by golden image prep).
CID_CHECK=$($SUDO /opt/CrowdStrike/falconctl -g --cid 2>/dev/null || true)
AID_CHECK=$($SUDO /opt/CrowdStrike/falconctl -g --aid 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' || true)
echo "falconctl CID: $CID_CHECK"
if [ -z "$AID_CHECK" ]; then
    echo "GOOD: No AID present (golden image prep succeeded). Each clone registers its own AID on first boot."
else
    echo "WARNING: An AID is still present ($AID_CHECK). Golden image prep may not have removed it."
fi

$SUDO rm -f "$SCRIPT_PATH"
echo "CrowdStrike Falcon Linux golden image preparation completed."
'''

// Replace Key Vault placeholder in script
var finalInstallScript = replace(falconInstallScript, 'KEYVAULT_NAME', keyVaultName)

// Best-effort OS package update (runs BEFORE the sensor install). Non-fatal so transient
// repo issues don't fail the whole build; distro-agnostic (apt/dnf/yum/zypper).
var osUpdateScript = '''
#!/bin/bash
set -u
echo "Applying OS package updates (best-effort)..."
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi
if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get -qq update || true
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get -qq -y upgrade || true
elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf -q -y upgrade || true
elif command -v yum >/dev/null 2>&1; then
    $SUDO yum -q -y update || true
elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive --quiet update -y || true
fi
echo "OS package update step complete."
'''

// =============================================================================
// MANAGED IDENTITY FOR AIB
// =============================================================================

resource aibManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: aibManagedIdentityName
  location: location
  tags: tags
}

// =============================================================================
// ROLE ASSIGNMENTS FOR AIB MANAGED IDENTITY
// =============================================================================

// Contributor role on resource group (required for AIB to create temporary resources)
resource contributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aibManagedIdentity.id, contributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: aibManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User role for accessing CrowdStrike credentials
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource keyVaultSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, aibManagedIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: aibManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Managed Identity Operator on the identity itself. Because we use the SAME user-assigned
// identity as both the template identity and the build-VM identity, the template identity
// must be able to operate (assign) that identity onto the build VM. Scope = the identity.
resource managedIdentityOperatorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aibManagedIdentity.id, aibManagedIdentity.id, managedIdentityOperatorRoleId)
  scope: aibManagedIdentity
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperatorRoleId)
    principalId: aibManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// AZURE IMAGE BUILDER TEMPLATE (LINUX)
// =============================================================================

resource imageBuilderTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2023-07-01' = {
  name: aibTemplateName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aibManagedIdentity.id}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: 90
    vmProfile: {
      vmSize: 'Standard_D2s_v3'
      // 0 = use the source image's own OS disk size. A fixed size fails if the base image's
      // disk is larger (e.g. RHEL 9-lvm-gen2 ships a 64 GB OS disk, Ubuntu 30 GB) with
      // "specified disk size N GB is smaller than the corresponding disk in the VM image".
      osDiskSizeGB: 0
      // Attach the user-assigned identity to the BUILD VM so the in-VM Shell customizer can
      // fetch an IMDS token and read Key Vault (verified via Microsoft Learn image-builder-json#identity).
      userAssignedIdentities: [
        aibManagedIdentity.id
      ]
    }
    source: {
      type: 'PlatformImage'
      publisher: sourceImagePublisher
      offer: sourceImageOffer
      sku: sourceImageSku
      version: sourceImageVersion
    }
    customize: [
      // Step 1: OS package updates (BEFORE the sensor install), best-effort.
      {
        type: 'Shell'
        name: 'OS-Package-Update'
        inline: [
          osUpdateScript
        ]
      }
      // Step 2: FINAL STEP - install CrowdStrike Falcon with PREP_GOLDEN_IMAGE=true.
      // AIB then generalizes the Linux image with `waagent -force -deprovision+user`.
      {
        type: 'Shell'
        name: 'Install-CrowdStrikeFalcon-GoldenImage'
        inline: [
          finalInstallScript
        ]
      }
    ]
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Compute/galleries/${sanitizedGalleryName}/images/${imageDefinitionName}'
        runOutputName: 'CrowdStrike-Golden-Image-Linux'
        artifactTags: {
          CrowdStrikeVersion: 'Latest'
          ImageVersion: imageVersion
          GoldenImagePrep: 'true'
        }
        versioning: {
          scheme: 'Source'
        }
        targetRegions: [
          {
            name: location
            replicaCount: 1
            storageAccountType: 'Standard_LRS'
          }
        ]
        excludeFromLatest: false
      }
    ]
  }
  dependsOn: [
    contributorRoleAssignment
    keyVaultSecretsUserRoleAssignment
    managedIdentityOperatorRoleAssignment
  ]
}

@description('Image Builder template name')
output templateName string = imageBuilderTemplate.name

@description('Image Builder template resource ID')
output templateId string = imageBuilderTemplate.id

@description('AIB managed identity resource ID')
output managedIdentityId string = aibManagedIdentity.id

@description('AIB managed identity principal ID')
output managedIdentityPrincipalId string = aibManagedIdentity.properties.principalId
