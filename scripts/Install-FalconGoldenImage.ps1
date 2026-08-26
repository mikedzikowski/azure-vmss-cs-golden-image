# =============================================================================
# CrowdStrike Falcon Sensor Golden Image Installation Script
# =============================================================================
# This script installs the CrowdStrike Falcon sensor in a golden image
# CRITICAL: Uses NO_START=1 to prevent sensor from starting and getting AID
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$FalconCloud = "autodiscover",

    [Parameter(Mandatory = $false)]
    [string]$SensorUpdatePolicyName = "platform_default",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\temp\crowdstrike-golden-image-install.log"
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
# MAIN INSTALLATION FUNCTION
# =============================================================================

function Install-CrowdStrikeFalconGoldenImage {
    Write-Log "========================================" -Level "INFO"
    Write-Log "CrowdStrike Falcon Golden Image Installation" -Level "INFO"
    Write-Log "========================================" -Level "INFO"
    Write-Log "CRITICAL: Installing with NO_START=1 to prevent AID assignment" -Level "WARNING"

    try {
        # Set TLS version for secure downloads
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "Set TLS 1.2 for secure communications" -Level "INFO"

        # Create temporary working directory
        $tempDir = "C:\temp\crowdstrike-install"
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Write-Log "Created temporary directory: $tempDir" -Level "INFO"

        # Get Azure managed identity token for Key Vault access
        Write-Log "Obtaining access token from Azure managed identity..." -Level "INFO"

        $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token"
        $tokenParams = @{
            'api-version' = '2018-02-01'
            'resource' = "https://$((Get-AzEnvironment -Name (Get-AzContext).Environment).KeyVaultDnsSuffix.TrimStart('.'))/"
        }

        # Fallback for when AzureRM/Az modules aren't available
        try {
            $kvResource = "https://vault.azure.net/"  # Default for Azure Public Cloud
            if ($env:AZURE_ENVIRONMENT -eq "AzureUSGovernment") {
                $kvResource = "https://vault.usgovcloudapi.net/"
            } elseif ($env:AZURE_ENVIRONMENT -eq "AzureChina") {
                $kvResource = "https://vault.azure.cn/"
            }
            $tokenParams.resource = $kvResource
        } catch {
            # Use default
        }

        $tokenQueryString = ($tokenParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $fullTokenUri = "$tokenUri?$tokenQueryString"

        $tokenResponse = Invoke-RestMethod -Uri $fullTokenUri -Method Get -Headers @{Metadata="true"} -UseBasicParsing -TimeoutSec 30

        if (-not $tokenResponse.access_token) {
            throw "Failed to obtain access token from managed identity"
        }

        Write-Log "Successfully obtained access token" -Level "SUCCESS"

        # Construct Key Vault URL
        $keyVaultUrl = "https://$KeyVaultName.vault.azure.net"
        $headers = @{
            'Authorization' = "Bearer $($tokenResponse.access_token)"
            'Content-Type' = 'application/json'
        }

        Write-Log "Retrieving CrowdStrike credentials from Key Vault: $KeyVaultName" -Level "INFO"

        # Retrieve required secrets from Key Vault
        $secrets = @{}
        $requiredSecrets = @('crowdstrike-client-id', 'crowdstrike-client-secret')
        $optionalSecrets = @('crowdstrike-falcon-cloud', 'crowdstrike-sensor-update-policy', 'crowdstrike-prov-token')

        foreach ($secretName in $requiredSecrets) {
            try {
                $secretResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/$secretName?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
                $secrets[$secretName] = $secretResponse.value
                Write-Log "Retrieved required secret: $secretName" -Level "SUCCESS"
            } catch {
                throw "Failed to retrieve required secret '$secretName': $($_.Exception.Message)"
            }
        }

        foreach ($secretName in $optionalSecrets) {
            try {
                $secretResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/$secretName?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
                $secrets[$secretName] = $secretResponse.value
                Write-Log "Retrieved optional secret: $secretName" -Level "INFO"
            } catch {
                Write-Log "Optional secret '$secretName' not found, will use default or skip" -Level "WARNING"
            }
        }

        # Download CrowdStrike PowerShell installation script
        Write-Log "Downloading CrowdStrike PowerShell installation script..." -Level "INFO"

        $scriptUrl = "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/refs/heads/main/powershell/install/falcon_windows_install.ps1"
        $scriptPath = Join-Path $tempDir "falcon_windows_install.ps1"

        try {
            Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing -TimeoutSec 120
            Write-Log "Successfully downloaded installation script" -Level "SUCCESS"
        } catch {
            throw "Failed to download CrowdStrike installation script: $($_.Exception.Message)"
        }

        # Verify script was downloaded
        if (-not (Test-Path $scriptPath)) {
            throw "Installation script not found at expected path: $scriptPath"
        }

        # Import the CrowdStrike installation module
        Write-Log "Importing CrowdStrike installation module..." -Level "INFO"
        try {
            Import-Module $scriptPath -Force -DisableNameChecking
            Write-Log "Successfully imported CrowdStrike module" -Level "SUCCESS"
        } catch {
            throw "Failed to import CrowdStrike module: $($_.Exception.Message)"
        }

        # Prepare installation parameters
        Write-Log "Preparing installation parameters..." -Level "INFO"

        $installParams = @{
            FalconClientId = $secrets['crowdstrike-client-id']
            FalconClientSecret = $secrets['crowdstrike-client-secret']
            InstallParams = "NO_START=1"  # CRITICAL: Prevents sensor from starting on image
        }

        # Add optional parameters if available
        if ($secrets['crowdstrike-falcon-cloud']) {
            $installParams['FalconCloud'] = $secrets['crowdstrike-falcon-cloud']
            Write-Log "Using Falcon Cloud: $($secrets['crowdstrike-falcon-cloud'])" -Level "INFO"
        } elseif ($FalconCloud -ne "autodiscover") {
            $installParams['FalconCloud'] = $FalconCloud
            Write-Log "Using provided Falcon Cloud: $FalconCloud" -Level "INFO"
        }

        if ($secrets['crowdstrike-sensor-update-policy']) {
            $installParams['SensorUpdatePolicyName'] = $secrets['crowdstrike-sensor-update-policy']
            Write-Log "Using Sensor Update Policy: $($secrets['crowdstrike-sensor-update-policy'])" -Level "INFO"
        } else {
            $installParams['SensorUpdatePolicyName'] = $SensorUpdatePolicyName
            Write-Log "Using default Sensor Update Policy: $SensorUpdatePolicyName" -Level "INFO"
        }

        if ($secrets['crowdstrike-prov-token']) {
            $installParams['ProvToken'] = $secrets['crowdstrike-prov-token']
            Write-Log "Using provisioning token for installation" -Level "INFO"
        }

        Write-Log "========================================" -Level "WARNING"
        Write-Log "INSTALLING CROWDSTRIKE FALCON SENSOR" -Level "WARNING"
        Write-Log "WITH NO_START=1 FLAG" -Level "WARNING"
        Write-Log "========================================" -Level "WARNING"

        # Execute the CrowdStrike installation
        Write-Log "Executing CrowdStrike Falcon sensor installation..." -Level "INFO"

        try {
            Install-FalconSensor @installParams -Verbose
            Write-Log "CrowdStrike Falcon sensor installation completed" -Level "SUCCESS"
        } catch {
            Write-Log "Installation failed: $($_.Exception.Message)" -Level "ERROR"
            Write-Log "Installation error details: $($_.ScriptStackTrace)" -Level "ERROR"
            throw
        }

        # Verify installation
        Write-Log "Verifying installation..." -Level "INFO"

        # Check for sensor binary
        $sensorPath = "${env:ProgramFiles}\CrowdStrike\WindowsSensor.exe"
        if (Test-Path $sensorPath) {
            Write-Log "SUCCESS: Sensor binary found at $sensorPath" -Level "SUCCESS"
        } else {
            throw "ERROR: Sensor binary not found at expected location: $sensorPath"
        }

        # Check for falconctl
        $falconCtlPath = "${env:ProgramFiles}\CrowdStrike\falconctl.exe"
        if (Test-Path $falconCtlPath) {
            Write-Log "SUCCESS: falconctl found at $falconCtlPath" -Level "SUCCESS"
        } else {
            throw "ERROR: falconctl not found at expected location: $falconCtlPath"
        }

        # Verify service exists but is not running (due to NO_START=1)
        $service = Get-Service -Name "CrowdStrike Falcon Sensor Service" -ErrorAction SilentlyContinue
        if ($service) {
            Write-Log "SUCCESS: CrowdStrike Falcon Sensor Service found" -Level "SUCCESS"
            Write-Log "Service Status: $($service.Status)" -Level "INFO"
            Write-Log "Service StartType: $($service.StartType)" -Level "INFO"

            if ($service.Status -eq 'Stopped') {
                Write-Log "EXCELLENT: Service is stopped as expected (NO_START=1 worked correctly)" -Level "SUCCESS"
            } else {
                Write-Log "WARNING: Service is not stopped - this may cause AID assignment issues" -Level "WARNING"
            }
        } else {
            throw "ERROR: CrowdStrike Falcon Sensor Service not found after installation"
        }

        Write-Log "========================================" -Level "SUCCESS"
        Write-Log "GOLDEN IMAGE INSTALLATION COMPLETED" -Level "SUCCESS"
        Write-Log "========================================" -Level "SUCCESS"
        Write-Log "CRITICAL REMINDERS:" -Level "WARNING"
        Write-Log "1. The sensor is installed but NOT started (NO_START=1)" -Level "WARNING"
        Write-Log "2. Do NOT reboot this image machine" -Level "WARNING"
        Write-Log "3. Seal the image immediately after this script completes" -Level "WARNING"
        Write-Log "4. Each VM from this image will get its own unique AID" -Level "WARNING"

    } catch {
        Write-Log "FATAL ERROR during CrowdStrike installation: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

        # Capture additional diagnostic information
        Write-Log "=== DIAGNOSTIC INFORMATION ===" -Level "INFO"

        try {
            # Check PowerShell execution policy
            $executionPolicy = Get-ExecutionPolicy
            Write-Log "PowerShell Execution Policy: $executionPolicy" -Level "INFO"

            # Check available disk space
            $diskSpace = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
                "$($_.DeviceID) - Free: $([math]::Round($_.FreeSpace/1GB,2)) GB / Total: $([math]::Round($_.Size/1GB,2)) GB"
            }
            Write-Log "Disk Space: $($diskSpace -join '; ')" -Level "INFO"

            # Check Windows version
            $osVersion = [System.Environment]::OSVersion.VersionString
            Write-Log "OS Version: $osVersion" -Level "INFO"

        } catch {
            Write-Log "Could not gather diagnostic information: $($_.Exception.Message)" -Level "WARNING"
        }

        throw
    } finally {
        # Cleanup
        Write-Log "Performing cleanup..." -Level "INFO"

        try {
            if (Test-Path $tempDir) {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Cleaned up temporary directory" -Level "INFO"
            }
        } catch {
            Write-Log "Warning: Could not clean up temporary directory: $($_.Exception.Message)" -Level "WARNING"
        }
    }
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    # Script is being executed directly
    try {
        Install-CrowdStrikeFalconGoldenImage

        Write-Log "Script completed successfully" -Level "SUCCESS"
        exit 0

    } catch {
        Write-Log "Script failed: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}