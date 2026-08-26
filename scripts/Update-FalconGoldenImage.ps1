# =============================================================================
# CrowdStrike Falcon Golden Image Update Runbook
# =============================================================================
# This script handles updating the golden image when a new sensor version is needed
# CRITICAL: Follows proper sequence to avoid AID contamination
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ImageBuilderTemplateName,

    [Parameter(Mandatory = $false)]
    [string]$NewImageVersion,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\temp\crowdstrike-image-update.log"
)

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to console with colors
    switch ($Level) {
        "INFO" { Write-Host $logEntry -ForegroundColor White }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
    }

    # Write to log file
    try {
        # Ensure log directory exists
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8
    } catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level "INFO"

    # Check if Azure CLI is available
    try {
        $azVersion = az version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Azure CLI is available" -Level "SUCCESS"
        } else {
            throw "Azure CLI is not available"
        }
    } catch {
        Write-Log "Azure CLI is required but not found. Please install Azure CLI." -Level "ERROR"
        throw
    }

    # Check if logged into Azure
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        if ($account) {
            Write-Log "Logged into Azure as: $($account.user.name)" -Level "SUCCESS"
        } else {
            throw "Not logged into Azure"
        }
    } catch {
        Write-Log "Not logged into Azure. Run 'az login' first." -Level "ERROR"
        throw
    }

    # Check if resource group exists
    try {
        $rg = az group show --name $ResourceGroupName 2>$null | ConvertFrom-Json
        if ($rg) {
            Write-Log "Resource group '$ResourceGroupName' exists" -Level "SUCCESS"
        } else {
            throw "Resource group not found"
        }
    } catch {
        Write-Log "Resource group '$ResourceGroupName' does not exist" -Level "ERROR"
        throw
    }

    Write-Log "Prerequisites check completed successfully" -Level "SUCCESS"
}

function Get-MaintenanceToken {
    Write-Log "Retrieving maintenance token from Key Vault..." -Level "INFO"

    try {
        $tokenJson = az keyvault secret show --vault-name $KeyVaultName --name "crowdstrike-maintenance-token" --query "value" -o tsv
        if ($tokenJson -and $tokenJson -ne "null") {
            Write-Log "Successfully retrieved maintenance token" -Level "SUCCESS"
            return $tokenJson
        } else {
            Write-Log "Maintenance token not found in Key Vault. This may cause uninstall issues." -Level "WARNING"
            return $null
        }
    } catch {
        Write-Log "Warning: Could not retrieve maintenance token: $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Update-ImageBuilderTemplate {
    param([string]$NewVersion)

    Write-Log "Updating Image Builder template with new image version..." -Level "INFO"

    try {
        # Get current template
        $templateJson = az image builder show --name $ImageBuilderTemplateName --resource-group $ResourceGroupName

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve Image Builder template"
        }

        $template = $templateJson | ConvertFrom-Json
        Write-Log "Current template retrieved successfully" -Level "SUCCESS"

        # Update image version in template properties if provided
        if ($NewVersion) {
            # This would require updating the template JSON and redeploying
            # For now, we'll use the existing template as-is
            Write-Log "New version specified: $NewVersion (template updates require redeployment)" -Level "INFO"
        }

        Write-Log "Image Builder template ready for new build" -Level "SUCCESS"

    } catch {
        Write-Log "Failed to update Image Builder template: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Start-ImageBuild {
    Write-Log "Starting Image Builder template execution..." -Level "INFO"

    try {
        # Start the image build
        Write-Log "Executing: az image builder run --name $ImageBuilderTemplateName --resource-group $ResourceGroupName" -Level "INFO"

        $buildOutput = az image builder run --name $ImageBuilderTemplateName --resource-group $ResourceGroupName --no-wait

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Image build started successfully (running in background)" -Level "SUCCESS"
            Write-Log "Monitor progress with: az image builder show-runs --name $ImageBuilderTemplateName --resource-group $ResourceGroupName" -Level "INFO"
        } else {
            throw "Failed to start image build"
        }

    } catch {
        Write-Log "Failed to start image build: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Wait-ForImageBuild {
    Write-Log "Waiting for image build to complete..." -Level "INFO"
    Write-Log "This process typically takes 30-60 minutes" -Level "INFO"

    $maxWaitTime = 7200  # 2 hours
    $checkInterval = 60  # 1 minute
    $elapsedTime = 0

    while ($elapsedTime -lt $maxWaitTime) {
        try {
            $runsJson = az image builder show-runs --name $ImageBuilderTemplateName --resource-group $ResourceGroupName
            $runs = $runsJson | ConvertFrom-Json

            if ($runs -and $runs.Count -gt 0) {
                $latestRun = $runs[0]
                $status = $latestRun.runState

                switch ($status) {
                    "Succeeded" {
                        Write-Log "Image build completed successfully!" -Level "SUCCESS"
                        return $true
                    }
                    "Failed" {
                        Write-Log "Image build failed. Check the run details for more information." -Level "ERROR"
                        Write-Log "Error details: $($latestRun.message)" -Level "ERROR"
                        return $false
                    }
                    "Running" {
                        Write-Log "Image build still in progress... (Status: $status)" -Level "INFO"
                    }
                    default {
                        Write-Log "Image build status: $status" -Level "INFO"
                    }
                }
            }

        } catch {
            Write-Log "Warning: Could not check build status: $($_.Exception.Message)" -Level "WARNING"
        }

        Start-Sleep -Seconds $checkInterval
        $elapsedTime += $checkInterval

        # Log progress every 10 minutes
        if ($elapsedTime % 600 -eq 0) {
            $minutesElapsed = $elapsedTime / 60
            Write-Log "Build has been running for $minutesElapsed minutes..." -Level "INFO"
        }
    }

    Write-Log "Timeout waiting for image build to complete" -Level "ERROR"
    return $false
}

function Update-VMSSToNewImage {
    param([string]$VMSSName, [string]$NewImageVersion)

    Write-Log "Updating VMSS '$VMSSName' to use new image version..." -Level "INFO"

    try {
        # This would require updating the VMSS image reference
        # Implementation depends on your specific VMSS deployment approach
        Write-Log "VMSS image update requires redeployment of VMSS Bicep template with new image version" -Level "INFO"
        Write-Log "Update the targetImageVersion parameter in your deployment to: $NewImageVersion" -Level "INFO"

    } catch {
        Write-Log "Failed to update VMSS: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# =============================================================================
# MAIN UPDATE FUNCTION
# =============================================================================

function Update-CrowdStrikeFalconGoldenImage {
    Write-Log "========================================" -Level "INFO"
    Write-Log "CrowdStrike Falcon Golden Image Update Process" -Level "INFO"
    Write-Log "========================================" -Level "INFO"
    Write-Log "CRITICAL PROCESS OVERVIEW:" -Level "WARNING"
    Write-Log "1. The existing image will be rebuilt with updated software" -Level "WARNING"
    Write-Log "2. CrowdStrike sensor will be uninstalled and reinstalled with NO_START=1" -Level "WARNING"
    Write-Log "3. New image will be sealed without reboot to preserve NO_START=1 state" -Level "WARNING"

    try {
        # Step 1: Prerequisites check
        Test-Prerequisites

        # Step 2: Get maintenance token for potential uninstall operations
        $maintenanceToken = Get-MaintenanceToken

        # Step 3: Update Image Builder template
        Update-ImageBuilderTemplate -NewVersion $NewImageVersion

        # Step 4: Start the image build process
        Start-ImageBuild

        # Step 5: Wait for build completion
        Write-Log "========================================" -Level "INFO"
        Write-Log "WAITING FOR IMAGE BUILD TO COMPLETE" -Level "INFO"
        Write-Log "========================================" -Level "INFO"

        $buildSuccess = Wait-ForImageBuild

        if ($buildSuccess) {
            Write-Log "========================================" -Level "SUCCESS"
            Write-Log "IMAGE BUILD COMPLETED SUCCESSFULLY" -Level "SUCCESS"
            Write-Log "========================================" -Level "SUCCESS"

            # Step 6: Provide next steps
            Write-Log "NEXT STEPS:" -Level "INFO"
            Write-Log "1. Verify the new image in Azure Compute Gallery" -Level "INFO"
            Write-Log "2. Update your VMSS deployment to use the new image version" -Level "INFO"
            Write-Log "3. Test the new image with a single VMSS instance first" -Level "INFO"
            Write-Log "4. Scale up VMSS after verifying sensor functionality" -Level "INFO"

            if ($NewImageVersion) {
                Write-Log "New image version: $NewImageVersion" -Level "INFO"
            } else {
                Write-Log "Check Azure Compute Gallery for the latest image version" -Level "INFO"
            }

        } else {
            Write-Log "========================================" -Level "ERROR"
            Write-Log "IMAGE BUILD FAILED" -Level "ERROR"
            Write-Log "========================================" -Level "ERROR"

            Write-Log "TROUBLESHOOTING STEPS:" -Level "INFO"
            Write-Log "1. Check Image Builder logs in the Azure portal" -Level "INFO"
            Write-Log "2. Verify Key Vault secrets are accessible" -Level "INFO"
            Write-Log "3. Check Image Builder managed identity permissions" -Level "INFO"
            Write-Log "4. Review the customization script for errors" -Level "INFO"

            throw "Image build process failed"
        }

    } catch {
        Write-Log "FATAL ERROR during golden image update: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
        throw
    }
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    # Script is being executed directly
    try {
        Update-CrowdStrikeFalconGoldenImage

        Write-Log "Image update process completed successfully" -Level "SUCCESS"
        exit 0

    } catch {
        Write-Log "Image update process failed: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}

# =============================================================================
# ADDITIONAL NOTES AND BEST PRACTICES
# =============================================================================

<#
GOLDEN IMAGE UPDATE BEST PRACTICES:

1. CRITICAL NO_START=1 BEHAVIOR:
   - NO_START=1 is only valid once - on the first boot after install
   - If an image is ever booted again after sensor install, the sensor WILL start
   - This would assign an AID to the image, causing all VMs to share the same AID
   - ALWAYS rebuild images rather than updating existing ones in place

2. UPDATE SEQUENCE:
   - The Azure Image Builder process automatically handles the correct sequence:
     a. Boot clean base image (Windows Server 2022)
     b. Apply Windows updates and reboot
     c. Install additional software if needed
     d. LAST STEP: Install CrowdStrike with NO_START=1
     e. Generalize and seal image WITHOUT rebooting

3. TESTING NEW IMAGES:
   - Always test new images with a single VMSS instance first
   - Verify sensor starts correctly and gets unique AID
   - Check sensor appears in CrowdStrike console
   - Only then scale up to production numbers

4. ROLLBACK STRATEGY:
   - Keep previous image versions available in Azure Compute Gallery
   - VMSS can be quickly rolled back to previous image version
   - Test rollback procedure in non-production environment

5. MAINTENANCE TOKENS:
   - Store CrowdStrike maintenance token in Key Vault
   - Required for clean sensor uninstall operations
   - Generate from CrowdStrike console under Host Management

6. MONITORING:
   - Monitor Image Builder execution through Azure Portal
   - Check logs in the temporary resource group created by AIB
   - Set up alerts for failed image builds

TROUBLESHOOTING COMMON ISSUES:

1. Build Timeout:
   - Increase buildTimeoutInMinutes in Bicep template
   - Check if external dependencies are accessible

2. Key Vault Access:
   - Verify managed identity has Key Vault Secrets User role
   - Check Key Vault network access settings

3. Sensor Download Failures:
   - Verify API credentials have required permissions
   - Check network connectivity to CrowdStrike APIs

4. Service Not Starting:
   - Verify CID format is correct
   - Check Windows Event Logs for CrowdStrike errors
   - Ensure provisioning token is valid if required

For more detailed troubleshooting, see:
- Azure Image Builder documentation
- CrowdStrike Falcon Windows deployment guide
- This solution's README.md file
#>