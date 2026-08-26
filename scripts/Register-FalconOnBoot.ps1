# =============================================================================
# CrowdStrike Falcon Sensor First Boot Registration Script
# =============================================================================
# This script registers the pre-installed sensor with CID and starts the service
# Runs on each new VMSS instance created from the golden image
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\temp\crowdstrike-registration.log"
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
# MAIN REGISTRATION FUNCTION
# =============================================================================

function Register-CrowdStrikeFalconOnBoot {
    Write-Log "========================================" -Level "INFO"
    Write-Log "CrowdStrike Falcon First Boot Registration" -Level "INFO"
    Write-Log "========================================" -Level "INFO"

    try {
        # Set TLS version for secure communications
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "Set TLS 1.2 for secure communications" -Level "INFO"

        # Verify CrowdStrike sensor is installed (from golden image)
        Write-Log "Verifying CrowdStrike sensor installation from golden image..." -Level "INFO"

        $sensorPath = "${env:ProgramFiles}\CrowdStrike\WindowsSensor.exe"
        $falconCtlPath = "${env:ProgramFiles}\CrowdStrike\falconctl.exe"

        if (-not (Test-Path $sensorPath)) {
            throw "CrowdStrike sensor binary not found at $sensorPath. Golden image may be corrupted."
        }

        if (-not (Test-Path $falconCtlPath)) {
            throw "falconctl.exe not found at $falconCtlPath. Golden image may be corrupted."
        }

        Write-Log "SUCCESS: CrowdStrike sensor binaries found from golden image" -Level "SUCCESS"

        # Get Azure managed identity token for Key Vault access
        Write-Log "Obtaining access token from Azure managed identity..." -Level "INFO"

        $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token"
        $tokenParams = @{
            'api-version' = '2018-02-01'
            'resource' = 'https://vault.azure.net/'  # Default for Azure Public Cloud
        }

        # Handle different Azure environments
        try {
            $azureEnv = $env:AZURE_ENVIRONMENT
            switch ($azureEnv) {
                "AzureUSGovernment" { $tokenParams.resource = "https://vault.usgovcloudapi.net/" }
                "AzureChina" { $tokenParams.resource = "https://vault.azure.cn/" }
                "AzureGermanCloud" { $tokenParams.resource = "https://vault.microsoftazure.de/" }
                default { $tokenParams.resource = "https://vault.azure.net/" }
            }
        } catch {
            # Use default
        }

        $tokenQueryString = ($tokenParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $fullTokenUri = "$tokenUri?$tokenQueryString"

        $tokenResponse = Invoke-RestMethod -Uri $fullTokenUri -Method Get -Headers @{Metadata="true"} -UseBasicParsing -TimeoutSec 30

        if (-not $tokenResponse.access_token) {
            throw "Failed to obtain access token from managed identity"
        }

        Write-Log "Successfully obtained access token for Key Vault access" -Level "SUCCESS"

        # Construct Key Vault URL (handle different Azure environments)
        $keyVaultDomain = "vault.azure.net"
        try {
            $azureEnv = $env:AZURE_ENVIRONMENT
            switch ($azureEnv) {
                "AzureUSGovernment" { $keyVaultDomain = "vault.usgovcloudapi.net" }
                "AzureChina" { $keyVaultDomain = "vault.azure.cn" }
                "AzureGermanCloud" { $keyVaultDomain = "vault.microsoftazure.de" }
                default { $keyVaultDomain = "vault.azure.net" }
            }
        } catch {
            # Use default
        }

        $keyVaultUrl = "https://$KeyVaultName.$keyVaultDomain"
        $headers = @{
            'Authorization' = "Bearer $($tokenResponse.access_token)"
            'Content-Type' = 'application/json'
        }

        Write-Log "Retrieving CrowdStrike CID from Key Vault: $KeyVaultName" -Level "INFO"

        # Retrieve CID (required)
        try {
            $cidResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-cid?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
            $cid = $cidResponse.value

            if (-not $cid) {
                throw "CID value is empty or null"
            }

            # Validate CID format (basic check)
            if ($cid -notmatch '^[0-9a-fA-F]{32}-[0-9a-fA-F]{2}$') {
                Write-Log "WARNING: CID format may be invalid. Expected format: XXXXXXXX-XX" -Level "WARNING"
            }

            Write-Log "Successfully retrieved CID from Key Vault" -Level "SUCCESS"

        } catch {
            throw "Failed to retrieve CID from Key Vault: $($_.Exception.Message)"
        }

        # Retrieve optional sensor tags
        $sensorTags = $null
        try {
            $tagsResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-tags?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
            $sensorTags = $tagsResponse.value
            Write-Log "Retrieved sensor tags: $sensorTags" -Level "INFO"
        } catch {
            Write-Log "No sensor tags found in Key Vault, continuing without tags" -Level "INFO"
        }

        # Retrieve optional provisioning token
        $provToken = $null
        try {
            $provTokenResponse = Invoke-RestMethod -Uri "$keyVaultUrl/secrets/crowdstrike-prov-token?api-version=7.4" -Method Get -Headers $headers -UseBasicParsing
            $provToken = $provTokenResponse.value
            Write-Log "Retrieved provisioning token" -Level "INFO"
        } catch {
            Write-Log "No provisioning token found in Key Vault, continuing without it" -Level "INFO"
        }

        # Configure CrowdStrike sensor with CID
        Write-Log "Configuring CrowdStrike sensor with CID..." -Level "INFO"

        try {
            # Set CID using falconctl
            $setCidArgs = @('-s', "--cid=$cid")
            $setCidResult = & $falconCtlPath $setCidArgs 2>&1

            if ($LASTEXITCODE -ne 0) {
                throw "falconctl set CID failed with exit code $LASTEXITCODE`: $setCidResult"
            }

            Write-Log "Successfully configured CID" -Level "SUCCESS"

        } catch {
            throw "Failed to set CID: $($_.Exception.Message)"
        }

        # Set sensor tags if available
        if ($sensorTags) {
            try {
                Write-Log "Setting sensor tags: $sensorTags" -Level "INFO"
                $setTagsArgs = @('-s', "--tags=$sensorTags")
                $setTagsResult = & $falconCtlPath $setTagsArgs 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Warning: Failed to set sensor tags (exit code $LASTEXITCODE): $setTagsResult" -Level "WARNING"
                } else {
                    Write-Log "Successfully set sensor tags" -Level "SUCCESS"
                }
            } catch {
                Write-Log "Warning: Exception while setting sensor tags: $($_.Exception.Message)" -Level "WARNING"
            }
        }

        # Set provisioning token if available
        if ($provToken) {
            try {
                Write-Log "Setting provisioning token" -Level "INFO"
                $setProvTokenArgs = @('-s', "--provisioning-token=$provToken")
                $setProvTokenResult = & $falconCtlPath $setProvTokenArgs 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Warning: Failed to set provisioning token (exit code $LASTEXITCODE): $setProvTokenResult" -Level "WARNING"
                } else {
                    Write-Log "Successfully set provisioning token" -Level "SUCCESS"
                }
            } catch {
                Write-Log "Warning: Exception while setting provisioning token: $($_.Exception.Message)" -Level "WARNING"
            }
        }

        # Start CrowdStrike Falcon sensor service
        Write-Log "Starting CrowdStrike Falcon sensor service..." -Level "INFO"

        $service = Get-Service -Name "CrowdStrike Falcon Sensor Service" -ErrorAction SilentlyContinue
        if (-not $service) {
            throw "CrowdStrike Falcon Sensor Service not found"
        }

        try {
            if ($service.Status -ne 'Running') {
                Start-Service -Name "CrowdStrike Falcon Sensor Service" -ErrorAction Stop
                Write-Log "Successfully started CrowdStrike Falcon sensor service" -Level "SUCCESS"
            } else {
                Write-Log "CrowdStrike Falcon sensor service was already running" -Level "INFO"
            }

            # Set service to automatic startup
            Set-Service -Name "CrowdStrike Falcon Sensor Service" -StartupType Automatic -ErrorAction Stop
            Write-Log "Set CrowdStrike service to automatic startup" -Level "SUCCESS"

        } catch {
            throw "Failed to start CrowdStrike service: $($_.Exception.Message)"
        }

        # Wait for service to initialize and verify status
        Write-Log "Waiting for service to initialize..." -Level "INFO"
        Start-Sleep -Seconds 15

        # Verify service is running
        $service = Get-Service -Name "CrowdStrike Falcon Sensor Service" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            Write-Log "SUCCESS: CrowdStrike Falcon sensor service is running" -Level "SUCCESS"
        } else {
            throw "CrowdStrike Falcon sensor service failed to start properly. Status: $($service.Status)"
        }

        # Attempt to get Agent ID (AID) - may not be immediately available
        Write-Log "Attempting to retrieve Agent ID (AID)..." -Level "INFO"

        try {
            $getAidArgs = @('-g', '--aid')
            $getAidResult = & $falconCtlPath $getAidArgs 2>&1

            if ($LASTEXITCODE -eq 0 -and $getAidResult -match "aid") {
                Write-Log "SUCCESS: Agent registered with CrowdStrike - $getAidResult" -Level "SUCCESS"
            } else {
                Write-Log "AID not yet available (normal for new registrations): $getAidResult" -Level "INFO"
                Write-Log "The agent will receive an AID once it connects to CrowdStrike cloud" -Level "INFO"
            }
        } catch {
            Write-Log "Could not retrieve AID (this is normal initially): $($_.Exception.Message)" -Level "INFO"
        }

        # Final verification
        Write-Log "Performing final verification..." -Level "INFO"

        # Check that we can get current CID
        try {
            $getCurrentCidArgs = @('-g', '--cid')
            $getCurrentCidResult = & $falconCtlPath $getCurrentCidArgs 2>&1

            if ($LASTEXITCODE -eq 0 -and $getCurrentCidResult -match "cid") {
                Write-Log "Verified CID configuration: $getCurrentCidResult" -Level "SUCCESS"
            } else {
                Write-Log "Warning: Could not verify CID configuration: $getCurrentCidResult" -Level "WARNING"
            }
        } catch {
            Write-Log "Warning: Exception while verifying CID: $($_.Exception.Message)" -Level "WARNING"
        }

        Write-Log "========================================" -Level "SUCCESS"
        Write-Log "FIRST BOOT REGISTRATION COMPLETED" -Level "SUCCESS"
        Write-Log "========================================" -Level "SUCCESS"
        Write-Log "CrowdStrike Falcon sensor is now active and will appear in the console" -Level "SUCCESS"

    } catch {
        Write-Log "FATAL ERROR during CrowdStrike registration: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

        # Capture diagnostic information for troubleshooting
        Write-Log "=== DIAGNOSTIC INFORMATION ===" -Level "INFO"

        try {
            # Check sensor files
            $sensorFiles = @(
                "${env:ProgramFiles}\CrowdStrike\WindowsSensor.exe",
                "${env:ProgramFiles}\CrowdStrike\falconctl.exe"
            )

            foreach ($file in $sensorFiles) {
                if (Test-Path $file) {
                    $fileInfo = Get-Item $file
                    Write-Log "Found: $file (Size: $($fileInfo.Length) bytes, Modified: $($fileInfo.LastWriteTime))" -Level "INFO"
                } else {
                    Write-Log "Missing: $file" -Level "ERROR"
                }
            }

            # Check service status
            $service = Get-Service -Name "CrowdStrike Falcon Sensor Service" -ErrorAction SilentlyContinue
            if ($service) {
                Write-Log "Service Status: $($service.Status)" -Level "INFO"
                Write-Log "Service StartType: $($service.StartType)" -Level "INFO"
            } else {
                Write-Log "Service not found" -Level "ERROR"
            }

            # Check Windows Event Log for CrowdStrike events
            try {
                $recentEvents = Get-EventLog -LogName Application -Source "*CrowdStrike*" -Newest 5 -ErrorAction SilentlyContinue
                if ($recentEvents) {
                    Write-Log "Recent CrowdStrike events found in Application log:" -Level "INFO"
                    foreach ($event in $recentEvents) {
                        Write-Log "  [$($event.TimeGenerated)] $($event.EntryType): $($event.Message.Substring(0, [Math]::Min(100, $event.Message.Length)))" -Level "INFO"
                    }
                } else {
                    Write-Log "No recent CrowdStrike events found in Application log" -Level "INFO"
                }
            } catch {
                Write-Log "Could not check Event Log: $($_.Exception.Message)" -Level "WARNING"
            }

            # Check network connectivity
            try {
                $testUrls = @("api.crowdstrike.com", "ts01-b.cloudsink.net")
                foreach ($url in $testUrls) {
                    $testResult = Test-NetConnection -ComputerName $url -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue
                    Write-Log "Network test to $url`: $testResult" -Level "INFO"
                }
            } catch {
                Write-Log "Could not perform network connectivity test: $($_.Exception.Message)" -Level "WARNING"
            }

        } catch {
            Write-Log "Could not gather complete diagnostic information: $($_.Exception.Message)" -Level "WARNING"
        }

        throw
    }
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    # Script is being executed directly
    try {
        Register-CrowdStrikeFalconOnBoot

        Write-Log "Script completed successfully" -Level "SUCCESS"
        exit 0

    } catch {
        Write-Log "Script failed: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}