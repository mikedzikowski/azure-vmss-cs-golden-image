// =============================================================================
// Azure Image Builder Module
// =============================================================================
// Creates Azure Image Builder template for CrowdStrike Falcon golden image
// CRITICAL: Installs sensor with NO_START=1 to prevent AID assignment on image
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

// Unique per (resource group + image definition), so different distros/OSes get distinct
// templates and re-running the same one idempotently updates its own. The resolved name is
// surfaced via the templateName output (use it for the portal/CLI "Start build").
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

// PowerShell script for CrowdStrike Falcon installation in golden image
// CRITICAL: Uses NO_START=1 to prevent sensor from starting and getting AID on image machine
var falconInstallScript = '''
# CrowdStrike Falcon Sensor Installation Script for Golden Image
# CRITICAL: This script MUST be run LAST in the image building process
# The NO_START=1 parameter prevents the sensor from starting and being assigned an AID

Write-Output "Starting CrowdStrike Falcon sensor installation for golden image..."
Write-Output "IMPORTANT: Installing with NO_START=1 to prevent AID assignment on image"

# Set security protocol for downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Create temp directory for downloads
$tempDir = "C:\temp\crowdstrike"
New-Item -ItemType Directory -Path $tempDir -Force
Set-Location $tempDir

try {
    # Get access token for Key Vault using managed identity
    Write-Output "Retrieving access token for Key Vault..."
    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Get -Headers @{Metadata="true"} -UseBasicParsing
    $accessToken = $tokenResponse.access_token

    if (-not $accessToken) {
        throw "Failed to obtain access token from managed identity"
    }

    Write-Output "Successfully obtained access token"

    # Key Vault base URL (KEYVAULT_NAME placeholder replaced at compile time via replace().
    # NOTE: this is a Bicep multi-line string which does NOT interpolate, so we must use
    # replace() rather than a dollar-brace expression for Bicep values. Public-cloud host.)
    $keyVaultUrl = "https://KEYVAULT_NAME.vault.azure.net"
    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type' = 'application/json'
    }

    # Retrieve CrowdStrike API credentials from Key Vault
    Write-Output "Retrieving CrowdStrike API credentials from Key Vault..."

    $clientIdResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-client-id?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
    $clientSecretResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-client-secret?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
    $falconCloudResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-falcon-cloud?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing

    $clientId = $clientIdResponse.value
    $clientSecret = $clientSecretResponse.value
    $falconCloud = $falconCloudResponse.value

    # Optional: Sensor Update Policy (defaults to platform_default if not found)
    try {
        $policyResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-sensor-update-policy?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
        $sensorUpdatePolicy = $policyResponse.value
    } catch {
        Write-Output "Sensor update policy not found in Key Vault, using platform_default"
        $sensorUpdatePolicy = "platform_default"
    }

    # Optional: Provisioning Token
    try {
        $provTokenResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-prov-token?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
        $provToken = $provTokenResponse.value
    } catch {
        Write-Output "Provisioning token not found in Key Vault, continuing without it"
        $provToken = $null
    }

    # Optional: explicit CID. If provided, it is used directly (script skips the API CCID
    # lookup). If absent, the install script retrieves the CCID from the Falcon API.
    try {
        $cidResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-cid?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
        $falconCid = $cidResponse.value
    } catch {
        Write-Output "No explicit CID in Key Vault, the installer will retrieve the CCID from the API"
        $falconCid = $null
    }

    Write-Output "Successfully retrieved CrowdStrike credentials"

    # Download CrowdStrike PowerShell installation script
    Write-Output "Downloading CrowdStrike PowerShell installation script..."
    $scriptUrl = "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/refs/heads/main/powershell/install/falcon_windows_install.ps1"
    $scriptPath = Join-Path $tempDir "falcon_windows_install.ps1"

    Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing

    if (-not (Test-Path $scriptPath)) {
        throw "Failed to download CrowdStrike installation script"
    }

    Write-Output "Successfully downloaded installation script"

    # Prepare installation parameters for the CrowdStrike install script.
    # IMPORTANT (verified against the vendor script source + repo README):
    #  - falcon_windows_install.ps1 is a STANDALONE script run directly (NOT a module;
    #    there is no Install-FalconSensor cmdlet).
    #  - Its -InstallParams REPLACES the default '/install /quiet /norestart', so we must
    #    pass the full string and append NO_START=1 to get the desired final command:
    #    WindowsSensor.exe /install /quiet /norestart NO_START=1
    #  - The script auto-retrieves the CCID from the API and bakes CID= into the install.
    #    NO_START=1 ensures the sensor never starts / never receives an AID in the image.
    $installParams = @{
        FalconClientId         = $clientId
        FalconClientSecret     = $clientSecret
        FalconCloud            = $falconCloud
        SensorUpdatePolicyName = $sensorUpdatePolicy
        InstallParams          = '/install /quiet /norestart NO_START=1'
    }

    # Add provisioning token if available
    if ($provToken) {
        $installParams['ProvToken'] = $provToken
        Write-Output "Using provisioning token for installation"
    }

    # Use an explicit CID if one was supplied (otherwise the script fetches the CCID).
    if ($falconCid) {
        $installParams['FalconCid'] = $falconCid
        Write-Output "Using explicitly provided CID for installation"
    }

    Write-Output "Installing CrowdStrike Falcon sensor with NO_START=1..."
    Write-Output "This ensures the sensor will not start or receive an AID on the image machine"

    # Execute the installation by invoking the script directly with splatted parameters.
    # NOTE: Do NOT gate on $LASTEXITCODE here. Invoking a .ps1 with & does not reliably set
    # $LASTEXITCODE (falcon_windows_install.ps1 never calls `exit` on success), so it can be
    # $null - and in PowerShell `$null -ne 0` is $true, which caused a FALSE failure even
    # though the sensor installed correctly. The vendor script THROWS a terminating error on
    # real failure (caught below), and the CSFalconService check is the true success gate.
    & $scriptPath @installParams

    Write-Output "CrowdStrike Falcon sensor installed successfully"
    Write-Output "Sensor is installed but NOT started (NO_START=1)"
    Write-Output "Each VM created from this image will get its own unique AID on first boot"

    # Verify the Windows sensor service exists but is stopped.
    # The Windows sensor service name is 'CSFalconService' (per the vendor script,
    # which detects an existing install via Get-Service Name -eq 'CSFalconService').
    $service = Get-Service -Name "CSFalconService" -ErrorAction SilentlyContinue
    if ($service) {
        Write-Output "SUCCESS: CSFalconService exists"
        Write-Output "Service Status: $($service.Status)"
        Write-Output "Service StartType: $($service.StartType)"

        if ($service.Status -eq 'Stopped') {
            Write-Output "GOOD: Service is stopped as expected (NO_START=1 worked)"
        } else {
            Write-Warning "WARNING: Service is not stopped - this may cause AID issues"
        }
    } else {
        throw "ERROR: CSFalconService not found after installation"
    }

} catch {
    Write-Error "CrowdStrike installation failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    throw
} finally {
    # Clean up temp directory
    Write-Output "Cleaning up temporary files..."
    Set-Location C:\
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "CrowdStrike Falcon sensor golden image installation completed successfully"
Write-Output "IMPORTANT: Do NOT reboot this image - seal immediately to preserve NO_START=1 state"
'''

// Replace Key Vault placeholder in script
var finalInstallScript = replace(falconInstallScript, 'KEYVAULT_NAME', keyVaultName)

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
// AZURE IMAGE BUILDER TEMPLATE
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
    buildTimeoutInMinutes: 120 // Golden image builds can take time
    vmProfile: {
      vmSize: 'Standard_D4s_v3' // Sufficient for image building with CrowdStrike
      // 0 = use the source image's own OS disk size (avoids "specified disk size smaller
      // than the corresponding disk in the VM image" if a base image's disk is larger).
      osDiskSizeGB: 0
      // Attach the user-assigned identity to the BUILD VM so in-VM customizer scripts can
      // fetch an IMDS token and read Key Vault. Without this, IMDS returns
      // {"error":"invalid_request","error_description":"Identity not found"} and the build
      // fails (verified via Microsoft Learn image-builder-json#identity, API 2021-10-01+).
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
      // Step 1: Windows Updates (MUST be done BEFORE CrowdStrike installation)
      {
        type: 'WindowsUpdate'
        searchCriteria: 'IsInstalled=0'
        filters: [
          'exclude:$_.Title -like "*Preview*"'
          'include:$true'
        ]
        updateLimit: 100
      }
      // Step 2: Restart after updates (REQUIRED before sensor installation)
      {
        type: 'WindowsRestart'
        restartCheckCommand: 'write-host "Restart completed after Windows Updates"'
        restartTimeout: '10m'
      }
      // Step 3: Install any additional software here if needed
      // Additional software installations should go here, before CrowdStrike

      // Step 4: FINAL STEP - Install CrowdStrike Falcon sensor with NO_START=1
      // CRITICAL: This MUST be the last step before generalization
      {
        type: 'PowerShell'
        name: 'Install-CrowdStrikeFalcon-GoldenImage'
        inline: [
          finalInstallScript
        ]
        runElevated: true
      }
      // Step 5: Final PowerShell cleanup (optional)
      {
        type: 'PowerShell'
        name: 'Final-Cleanup'
        inline: [
          'Write-Output "Performing final cleanup for golden image..."'
          'Get-EventLog -LogName Application -Source "CrowdStrike*" -Newest 10 -ErrorAction SilentlyContinue | Format-Table -AutoSize'
          'Write-Output "Golden image preparation completed - ready for generalization"'
          'Write-Output "IMPORTANT: Image will be sealed without reboot to preserve NO_START=1 state"'
        ]
        runElevated: true
      }
    ]
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Compute/galleries/${sanitizedGalleryName}/images/${imageDefinitionName}'
        runOutputName: 'CrowdStrike-Golden-Image'
        artifactTags: {
          CrowdStrikeVersion: 'Latest'
          ImageVersion: imageVersion
          NoStartFlag: 'true'
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