# Script to automatically configure Nginx Proxy Manager
param (
    [string]$OpenEMRContainer = "",
    [string]$TelehealthContainer = "",
    [string]$JitsiContainer = "",
    [string]$AdminEmail = "admin@example.com",
    [string]$AdminPassword = "changeme",
    [string]$NpmUrl = "http://localhost:81",
    [switch]$ForceSSL = $false,
    [switch]$EnableHTTP2 = $false,
    [string]$Environment = "production",
    [switch]$ReplaceCertificate = $false,
    [switch]$Force,
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",  # Path to source repositories
    [int]$certificate_id = 0,  # Changed from CertificateId to certificate_id to match NPM expectations
    [string]$Project = "aiotp",  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
    [int]$CertificateId,
    [switch]$NonInteractive = $false,
    [string]$DomainBase = "localhost"
)

# Get environment configuration
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase

# Load environment configuration if available
$envConfig = $null
if (-not [string]::IsNullOrEmpty($Environment)) {
    try {
        $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project
        Write-Host "Loaded environment configuration for project: $Project, environment: $Environment" -ForegroundColor Green
        
        # Only use environment config for NpmUrl if no URL was provided
        if ([string]::IsNullOrEmpty($NpmUrl)) {
            $adminPort = $envConfig.NpmPorts.admin  # Changed from $envConfig.Config.npmPorts.admin
            Write-Host "Got NPM admin port from config: $adminPort" -ForegroundColor Cyan
            if ($adminPort) {
                $NpmUrl = "http://localhost:$adminPort"
                Write-Host "Using environment-specific NPM URL: $NpmUrl" -ForegroundColor Green
            } else {
                Write-Host "Warning: Could not get NPM admin port from environment config" -ForegroundColor Yellow
                $NpmUrl = "http://localhost:81"  # Fallback to default only if no port found
                Write-Host "Falling back to default NPM URL: $NpmUrl" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Using provided NPM URL: $NpmUrl" -ForegroundColor Green
        }
    } catch {
        Write-Host "Failed to load environment configuration: $_" -ForegroundColor Yellow
        if ([string]::IsNullOrEmpty($NpmUrl)) {
            $NpmUrl = "http://localhost:81"  # Fallback to default if config load fails
            Write-Host "Falling back to default NPM URL: $NpmUrl" -ForegroundColor Yellow
        }
    }
} elseif ([string]::IsNullOrEmpty($NpmUrl)) {
    $NpmUrl = "http://localhost:81"  # Fallback to default if no environment specified
    Write-Host "No environment specified. Using default NPM URL: $NpmUrl" -ForegroundColor Yellow
}

# Set base project name based on environment config
$baseProjectName = if ($envConfig) {
    $envConfig.ProjectName
} else {
    "aiotp"
}

# Define folder names for each component
$openemrFolder = "openemr"
$telehealthFolder = "telehealth"
$jitsiFolder = "jitsi-docker"
$proxyFolder = "proxy"

# Source repository variables
$openemrSourceDir = "$SourceReposDir\openemr-telesalud"
$telehealthSourceDir = "$SourceReposDir\ciips-telesalud"

# Check if source repositories exist
if (Test-Path $openemrSourceDir) {
    Write-Host "Found OpenEMR source repository at: $openemrSourceDir" -ForegroundColor Green
} else {
    Write-Host "OpenEMR source repository not found at: $openemrSourceDir" -ForegroundColor Yellow
}

if (Test-Path $telehealthSourceDir) {
    Write-Host "Found Telehealth source repository at: $telehealthSourceDir" -ForegroundColor Green
} else {
    Write-Host "Telehealth source repository not found at: $telehealthSourceDir" -ForegroundColor Yellow
}

# If credentials are not provided, prompt for them
if ([string]::IsNullOrEmpty($AdminEmail) -or [string]::IsNullOrEmpty($AdminPassword)) {
    Write-Host "Nginx Proxy Manager credentials are required." -ForegroundColor Yellow
    $AdminEmail = Read-Host "Enter your Nginx Proxy Manager email"
    # Read password as plain text for simplicity
    $AdminPassword = Read-Host "Enter your Nginx Proxy Manager password"
}

# Detect containers using environment-specific patterns
$OpenEMRContainer = docker ps --format "{{.Names}}" | Where-Object { 
    $_ -like "*openemr*" -and 
    ($_ -like "*openemr-1" -or $_ -like "$baseProjectName-openemr-1") 
} | Select-Object -First 1

if (-not $OpenEMRContainer) {
    # Try to detect OpenEMR-Telesalud container
    $OpenEMRContainer = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*openemr-telesalud*" -or $_ -like "*$baseProjectName-openemr-1*"
    } | Select-Object -First 1
}

# Special handling for official OpenEMR project
if (-not $OpenEMRContainer -and $Project -eq "official") {
    $OpenEMRContainer = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "$baseProjectName*" -and $_ -like "*openemr"
    } | Select-Object -First 1
}

Write-Host "Detected OpenEMR container: $OpenEMRContainer"

# Detect telehealth containers using environment-specific patterns
$TelehealthAppContainer = docker ps --format "{{.Names}}" | Where-Object { 
    $_ -like "*$baseProjectName-telehealth*" -and $_ -like "*app-1" 
} | Select-Object -First 1
$TelehealthWebContainer = docker ps --format "{{.Names}}" | Where-Object { 
    $_ -like "*$baseProjectName-telehealth*" -and $_ -like "*web-1" 
} | Select-Object -First 1
Write-Host "Detected Telehealth app container: $TelehealthAppContainer"
Write-Host "Detected Telehealth web container: $TelehealthWebContainer"

# Try to detect shared Jitsi container first, then fall back to environment-specific
$JitsiContainer = docker ps --format "{{.Names}}" | Where-Object { 
    $_ -like "*jitsi-docker*" -and $_ -like "*web-1" 
} | Select-Object -First 1

if (-not $JitsiContainer) {
    # Fall back to environment-specific Jitsi container
    $JitsiContainer = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*$baseProjectName-jitsi*" -and $_ -like "*web-1" 
    } | Select-Object -First 1
}

Write-Host "Detected Jitsi container: $JitsiContainer"
if ($JitsiContainer -like "*jitsi-docker*") {
    Write-Host "Using shared Jitsi instance" -ForegroundColor Green
} elseif ($JitsiContainer) {
    Write-Host "Using environment-specific Jitsi instance" -ForegroundColor Green
} else {
    Write-Host "No Jitsi container detected" -ForegroundColor Yellow
}

# Function to check if NPM is ready
function Test-NpmReady {
    try {
        $response = Invoke-WebRequest -Uri "$NpmUrl" -Method Get -UseBasicParsing -ErrorAction SilentlyContinue
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

# Function to wait for NPM to be ready
function Wait-ForNpm {
    $maxRetries = 3
    $retryCount = 0
    $retryInterval = 5 # seconds
    
    Write-Host "Waiting for Nginx Proxy Manager to be ready..." -ForegroundColor Yellow
    
    while (-not (Test-NpmReady) -and $retryCount -lt $maxRetries) {
        $retryCount++
        Write-Host "Attempt $retryCount of $maxRetries - NPM not ready yet. Waiting $retryInterval seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryInterval
    }
    
    if ($retryCount -ge $maxRetries) {
        Write-Host "Failed to connect to Nginx Proxy Manager after $maxRetries attempts." -ForegroundColor Red
        return $false
    }
    
    # Add additional delay to ensure the database is fully initialized
    Write-Host "Nginx Proxy Manager is ready! Waiting 10 seconds for database initialization..." -ForegroundColor Green
    Start-Sleep -Seconds 10
    
    return $true
}

# Function to get authentication token
function Get-NpmToken {
    $loginData = @{
        identity = $AdminEmail
        secret = $AdminPassword
    } | ConvertTo-Json
    
    $maxRetries = 5
    $retryCount = 0
    $retryInterval = 5 # seconds
    
    while ($retryCount -lt $maxRetries) {
        try {
            $response = Invoke-RestMethod -Uri "$NpmUrl/api/tokens" -Method Post -Body $loginData -ContentType "application/json" -ErrorAction Stop
            return $response.token
        } catch {
            $retryCount++
            Write-Host "Authentication attempt $retryCount of $maxRetries failed: $_" -ForegroundColor Yellow
            
            if ($retryCount -ge $maxRetries) {
                Write-Host "Failed to authenticate with Nginx Proxy Manager after $maxRetries attempts." -ForegroundColor Red
                Write-Host "Please verify that the Nginx Proxy Manager is running and the credentials are correct." -ForegroundColor Red
                Write-Host "You may need to manually configure the Nginx Proxy Manager at $NpmUrl" -ForegroundColor Yellow
                return $null
            }
            
            Write-Host "Waiting $retryInterval seconds before retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds $retryInterval
        }
    }
}

# Function to get existing proxy hosts
function Get-ProxyHosts {
    param (
        [string]$NpmUrl,
        [string]$Token
    )
    
    try {
        $response = Invoke-RestMethod -Uri "$NpmUrl/api/nginx/proxy-hosts" -Method Get -Headers @{
            "Authorization" = "Bearer $Token"
        }
        return $response
    } catch {
        Write-Host "Failed to get proxy hosts: $_" -ForegroundColor Red
        return $null
    }
}

# Function to delete a proxy host
function Remove-ProxyHost {
    param (
        [string]$NpmUrl,
        [string]$Token,
        [int]$ProxyHostId
    )
    
    try {
        $response = Invoke-RestMethod -Uri "$NpmUrl/api/nginx/proxy-hosts/$ProxyHostId" -Method Delete -Headers @{
            "Authorization" = "Bearer $Token"
        }
        return $true
    } catch {
        Write-Host "Failed to delete proxy host: $_" -ForegroundColor Red
        return $false
    }
}

# Function to create or update a proxy host
function New-ProxyHost {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Token,
        [Parameter(Mandatory=$true)]
        [string[]]$DomainNames,
        [Parameter(Mandatory=$true)]
        [string]$ForwardHost,
        [Parameter(Mandatory=$true)]
        [int]$ForwardPort,
        [Parameter(Mandatory=$false)]
        [string]$ForwardPath = "/",
        [Parameter(Mandatory=$false)]
        [int]$certificate_id = 0,
        [Parameter(Mandatory=$false)]
        [bool]$BlockExploits = $true,
        [Parameter(Mandatory=$false)]
        [bool]$AllowWebsocket = $false,
        [Parameter(Mandatory=$false)]
        [bool]$HTTP2Support = $true,
        [Parameter(Mandatory=$false)]
        [bool]$ForceSSL = $true,
        [Parameter(Mandatory=$false)]
        [switch]$Force,
        [Parameter(Mandatory=$false)]
        [string]$CustomLocation = "",
        [Parameter(Mandatory=$false)]
        [bool]$CachingEnabled = $false,
        [Parameter(Mandatory=$false)]
        [string]$AdvancedConfig = "",
        [Parameter(Mandatory=$false)]
        [int]$AccessListId = 0,
        [Parameter(Mandatory=$false)]
        [bool]$HSTSEnabled = $false,
        [Parameter(Mandatory=$false)]
        [int]$HSTSMaxAge = 63072000,
        [Parameter(Mandatory=$false)]
        [bool]$HSTSIncludeSubdomains = $false,
        [Parameter(Mandatory=$false)]
        [bool]$HSTSPreload = $false
    )
    
    # Check if proxy host already exists
    if ($Force) {
        $existingHosts = Get-ProxyHosts -NpmUrl $NpmUrl -Token $Token
        $existingHost = $existingHosts | Where-Object { 
            $hostDomains = $_.domain_names
            $DomainNames | ForEach-Object { 
                if ($hostDomains -contains $_) { return $true }
            }
            return $false
        }
        
        if ($existingHost) {
            Write-Host "Proxy host for $($DomainNames -join ', ') already exists (ID: $($existingHost.id)). Deleting..." -ForegroundColor Yellow
            $deleted = Remove-ProxyHost -NpmUrl $NpmUrl -Token $Token -ProxyHostId $existingHost.id
            if (-not $deleted) {
                Write-Host "Failed to delete existing proxy host. Skipping..." -ForegroundColor Red
                return $null
            }
            Write-Host "Existing proxy host deleted successfully." -ForegroundColor Green
        }
    }
    
    # Create proxy host configuration
    $proxyData = @{
        domain_names = $DomainNames
        forward_host = $ForwardHost
        forward_port = 80
        forward_scheme = "http"
        block_exploits = $BlockExploits
        allow_websocket_upgrade = $AllowWebsocket
    }
    
    # Add certificate ID if provided
    if ($certificate_id -ne 0) {
        $proxyData.certificate_id = $certificate_id
        $proxyData.ssl_forced = $ForceSSL
        $proxyData.http2_support = $HTTP2Support
    }
    
    # Add custom location if provided
#    if ($CustomLocation -ne "") {
#        $proxyData.locations = @(
#            @{
#                path = $CustomLocation
#                forward_scheme = "http"
#                forward_host = $ForwardHost
#                forward_port = $ForwardPort
#            }
#        )
#    }
    
    # Add HSTS settings if enabled
    if ($HSTSEnabled) {
        $proxyData.hsts_enabled = $true
        $proxyData.hsts_max_age = $HSTSMaxAge
        $proxyData.hsts_include_subdomains = $HSTSIncludeSubdomains
        $proxyData.hsts_preload = $HSTSPreload
    }
    
    # Add caching if enabled
    if ($CachingEnabled) {
        $proxyData.caching_enabled = $true
    }
    
    # Add access list if provided
    if ($AccessListId -ne 0) {
        $proxyData.access_list_id = $AccessListId
    }
    
    # Add advanced config if provided
    if ($AdvancedConfig -ne "") {
        $proxyData.advanced_config = $AdvancedConfig
    }
    
    $jsonPayload = $proxyData | ConvertTo-Json -Depth 10
    
    try {
        # Check if proxy host already exists
        $existingHosts = Get-ProxyHosts -NpmUrl $NpmUrl -Token $Token
        $existingHost = $existingHosts | Where-Object { $_.domain_names -contains $DomainNames[0] }
        
        if ($existingHost -and -not $Force) {
            Write-Host "Proxy host for $($DomainNames[0]) already exists (ID: $($existingHost.id))" -ForegroundColor Yellow
            
            # Check if certificate ID needs to be updated
            if ($certificate_id -ne 0 -and $existingHost.certificate_id -ne $certificate_id) {
                Write-Host "Certificate ID mismatch for proxy host $($DomainNames[0]). Current: $($existingHost.certificate_id), New: $certificate_id" -ForegroundColor Yellow
                if ($ReplaceCertificate) {
                    Write-Host "Updating certificate ID..." -ForegroundColor Yellow
                    $certToReplace = $existingHost
                    return $null
                } else {
                    Write-Host "Use the -ReplaceCertificate switch to update the certificate" -ForegroundColor Yellow
                }
            }
            
            return $existingHost
        }
        
        # Create new proxy host
        Write-Host "Creating new proxy host for $($DomainNames[0])..." -ForegroundColor Yellow
        Write-Host "Configuration:" -ForegroundColor Yellow
        Write-Host $jsonPayload -ForegroundColor Yellow
        
        $response = Invoke-RestMethod -Uri "$NpmUrl/api/nginx/proxy-hosts" -Method Post -Headers @{
            "Authorization" = "Bearer $Token"
        } -Body $jsonPayload -ContentType "application/json"
        
        return $response
    } catch {
        Write-Host "Failed to create proxy host for $($DomainNames[0]): $_" -ForegroundColor Red
        if ($_.Exception.Response.StatusCode -eq 400) {
            try {
                $responseBody = $_.ErrorDetails.Message
                Write-Host "Response body: $responseBody" -ForegroundColor Red
            } catch {
                Write-Host "Could not get response body" -ForegroundColor Red
            }
        }
        return $null
    }
}

# Function to create a self-signed certificate
function New-SelfSignedCertificate {
    param (
        [string]$Token,
        [string]$Name,
        [string[]]$Domains,
        [switch]$ReplaceCertificate
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }
    
    # Check if certificate already exists
    try {
        $existingCerts = Invoke-RestMethod -Uri "$NpmUrl/api/nginx/certificates" -Method Get -Headers $headers -ErrorAction Stop
        $certToReplace = $null
        
        foreach ($cert in $existingCerts) {
            $matchingDomains = $true
            foreach ($domain in $Domains) {
                if ($cert.domain_names -notcontains $domain) {
                    $matchingDomains = $false
                    break
                }
            }
            
            if ($matchingDomains) {
                Write-Host "Certificate for $($Domains -join ', ') already exists (ID: $($cert.id))" -ForegroundColor Yellow
                if ($ReplaceCertificate) {
                    Write-Host "Replacing existing certificate..." -ForegroundColor Yellow
                    $certToReplace = $cert
                    return $null
                } else {
                    return $cert
                }
            }
        }
        
        # If we get here, no matching certificate was found
        # Look for any certificate we can use
        if ($existingCerts.Count -gt 0 -and -not $ReplaceCertificate) {
            Write-Host "Using existing certificate (ID: $($existingCerts[0].id))" -ForegroundColor Yellow
            return $existingCerts[0]
        }
    } catch {
        Write-Host "Error checking existing certificates: $_" -ForegroundColor Yellow
    }
    
    # Check if we have a local certificate file
    $certDir = ".\environment\ssl"
    $certPath = if ($envConfig) {
        "$certDir\$($envConfig.Environment)-certificate.crt"
    } else {
        "$certDir\certificate.crt"
    }
    $keyPath = if ($envConfig) {
        "$certDir\$($envConfig.Environment)-private.key"
    } else {
        "$certDir\private.key"
    }
    
    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        Write-Host "Found local certificate files at:" -ForegroundColor Green
        Write-Host "  Certificate: $certPath" -ForegroundColor Green
        Write-Host "  Private Key: $keyPath" -ForegroundColor Green
        
        # Set a default certificate ID
        $certId = 1
        Write-Host "Using default certificate ID: $certId" -ForegroundColor Yellow
        
        Write-Host "Creating proxy hosts..." -ForegroundColor Green
        return @{ id = $certId }
    } elseif ($certToReplace -and $ReplaceCertificate) {
        # If we don't have certificate files but need to replace a certificate, use the API
        $certId = $certToReplace.id
        $certData = @{
            name = $Name
            domain_names = $Domains
            cert = ""
            key = ""
            ca = ""
            meta = @{
                letsencrypt_agree = $false
                dns_challenge = $false
            }
        } | ConvertTo-Json
        
        try {
            $updateResponse = Invoke-RestMethod -Uri "$NpmUrl/api/nginx/certificates/$certId" -Method Put -Headers $headers -Body $certData -ErrorAction Stop
            Write-Host "Certificate replaced successfully" -ForegroundColor Green
            return $updateResponse
        } catch {
            Write-Host "Failed to replace certificate: $($_.Exception.Message)" -ForegroundColor Red
            return $certToReplace
        }
    }
    
    Write-Host "No certificates found. Using default certificate." -ForegroundColor Yellow
    return @{ id = 0 }
}

# Function to detect NPM container
function Get-NpmContainer {
    param (
        [string]$ProjectName,
        [string]$Environment
    )
    
    $containerPattern = "$ProjectName-$Environment-proxy-proxy-1"
    Write-Host "Looking for NPM container with pattern: $containerPattern" -ForegroundColor Yellow
    
    $container = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -eq $containerPattern
    } | Select-Object -First 1
    
    if ($container) {
        Write-Host "Found NPM container: $container" -ForegroundColor Green
    } else {
        Write-Host "NPM container not found with pattern: $containerPattern" -ForegroundColor Yellow
    }
    
    return $container
}

# Function to fix NPM network connections
function Fix-NpmNetwork {
    param (
        [string]$Environment,
        [string]$ProjectName
    )
    
    Write-Host "Fixing NPM network for $ProjectName-$Environment environment ($Environment)..." -ForegroundColor Yellow
    
    # Get NPM container
    $npmContainer = Get-NpmContainer -ProjectName $ProjectName -Environment $Environment
    if (-not $npmContainer) {
        Write-Host "NPM container not found. Please ensure the proxy service is running." -ForegroundColor Red
        return
    }
    
    # Get network configuration
    $networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $ProjectName -DomainBase $DomainBase
    
    # Connect NPM container to frontend network if not already connected
    $frontendNetwork = $networkConfig.FrontendNetwork
    $isConnected = docker network inspect $frontendNetwork --format '{{range .Containers}}{{.Name}} {{end}}' | Select-String -Pattern $npmContainer
    
    if (-not $isConnected) {
        Write-Host "Connecting NPM container to frontend network..." -ForegroundColor Yellow
        docker network connect $frontendNetwork $npmContainer
        Write-Host "Connected NPM container to frontend network" -ForegroundColor Green
    } else {
        Write-Host "NPM container already connected to frontend network" -ForegroundColor Green
    }
}

# Main script execution
if (-not (Wait-ForNpm)) {
    exit 1
}

# Get authentication token
$token = Get-NpmToken
if (-not $token) {
    exit 1
}

Write-Host "Successfully authenticated with Nginx Proxy Manager" -ForegroundColor Green

# Find certificates
Write-Host "Looking for existing certificates..." -ForegroundColor Yellow
if ($envConfig) {
    $domains = @(
        $envConfig.Domains.openemr,
        $envConfig.Domains.telehealth,
        $envConfig.Domains.jitsi
    )
    $certName = "All-In-One Telehealth Platform ($($envConfig.Environment))"
} else {
    $domains = @("localhost", "vc.localhost", "vcbknd.localhost")
    $certName = "All-In-One Telehealth Platform"
}

# Check if certificate ID was provided as a parameter
if ($certificate_id -gt 0) {
    Write-Host "Using provided Certificate ID: $certificate_id" -ForegroundColor Green
    $certId = $certificate_id
} else {
    # Check if we have a local certificate file and import it using Selenium
    $certDir = ".\environment\ssl"
    if ($envConfig) {
        $certPath = "$certDir\$($envConfig.Environment)-certificate.crt"
        $keyPath = "$certDir\$($envConfig.Environment)-private.key"
    } else {
        $certPath = "$certDir\certificate.crt"
        $keyPath = "$certDir\private.key"
    }

    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        Write-Host "Found local certificate files. Using API-based import..." -ForegroundColor Green
        
        # Import certificate using API
        $certName = if ($envConfig) {
            "All-In-One Telehealth Platform ($($envConfig.Environment))"
        } else {
            "All-In-One Telehealth Platform"
        }
        
        try {
            $certContent = Get-Content $certPath -Raw
            $keyContent = Get-Content $keyPath -Raw
            
            $certData = @{
                name = $certName
                cert = $certContent
                key = $keyContent
            }
            
            $headers = @{
                "Content-Type" = "application/json"
                "Authorization" = "Bearer $token"
            }
            
            $response = Invoke-RestMethod -Uri "$NpmUrl/api/ssl" -Method Post -Headers $headers -Body ($certData | ConvertTo-Json)
            if ($response) {
                $certId = $response.id
                Write-Host "Certificate imported successfully. Using certificate ID: $certId" -ForegroundColor Green
            } else {
                Write-Host "Failed to import certificate using API" -ForegroundColor Red
                $certId = 1
            }
        } catch {
            Write-Host "Failed to import certificate using API: $_" -ForegroundColor Red
            Write-Host "Using default certificate ID: 1" -ForegroundColor Yellow
            $certId = 1
        }
    } else {
        # If we don't have local certificate files, try to use the API to find or create one
        $localhostCert = New-SelfSignedCertificate -Token $token -Name $certName -Domains $domains -ReplaceCertificate:$ReplaceCertificate
        if ($localhostCert) {
            $certId = $localhostCert.id
            Write-Host "Using certificate with ID: $certId" -ForegroundColor Green
        } else {
            Write-Host "No certificate found. Using default certificate." -ForegroundColor Yellow
            $certId = 1
        }
    }
}

# Create proxy hosts
Write-Host "Creating proxy hosts..." -ForegroundColor Yellow

if ($envConfig) {
    Write-Host "Creating proxy hosts for $($envConfig.Environment) environment..." -ForegroundColor Cyan
    
    # Set the container name based on project
    $openemrContainerName = if ($Project -eq "official") {
        # Official project uses a different container name pattern
        "$baseProjectName-openemr-1"
    } else {
        # Default projects use this pattern
        "$baseProjectName-openemr-openemr-1"
    }
    
    # Determine the forward port based on project
    $forwardPort = if ($Project -eq "official") {
        # Official project forwards directly to container port 80
        80
    } else {
        # Default projects may use a custom port from the config
        $envConfig.NpmPorts.http
    }
    
    # WordPress (Main Site) - This will be at the base domain with environment prefix for non-production
    # WordPress container uses the project name with -wordpress suffix
    $wordpressContainerName = "$baseProjectName-wordpress-wordpress-1"
    
    # WordPress domain should include environment prefix for non-production
    $wordpressDomain = if ($Environment -eq "production") {
        # Production uses the base domain (e.g., vr2fit.com)
        $DomainBase
    } else {
        # Non-production environments use the environment name as prefix
        "$($Environment.ToLower()).$DomainBase"
    }
    
    # WordPress proxy host - this will route to WordPress
    Write-Host "Setting up WordPress proxy host for domain: $wordpressDomain" -ForegroundColor Cyan
    Write-Host "WordPress container: $wordpressContainerName" -ForegroundColor Cyan
    
    # Make sure the container exists before creating the proxy host
    $wordpressContainerExists = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $wordpressContainerName }
    
    if ($wordpressContainerExists) {
        $wordpressResponse = New-ProxyHost -Token $token -DomainNames @($wordpressDomain) -ForwardHost $wordpressContainerName -ForwardPort 80 -BlockExploits $true -AllowWebsocket $false -ForceSSL $true -HTTP2Support $true -certificate_id $certId -Force:$Force
        if ($wordpressResponse) {
            Write-Host "WordPress proxy host created or found successfully for domain: $wordpressDomain" -ForegroundColor Green
        } else {
            Write-Host "Failed to create WordPress proxy host for domain: $wordpressDomain" -ForegroundColor Red
        }
    } else {
        Write-Host "WordPress container not found. Skipping proxy host creation." -ForegroundColor Yellow
    }
    
    # OpenEMR - keep it at its current domain (e.g., notes.localhost or staging-notes.localhost)
    $openemrResponse = New-ProxyHost -Token $token -DomainNames @($envConfig.Domains.openemr) -ForwardHost $openemrContainerName -ForwardPort $forwardPort -BlockExploits $true -AllowWebsocket $false -ForceSSL $true -HTTP2Support $true -certificate_id $certId -Force:$Force
    if ($openemrResponse) {
        Write-Host "OpenEMR proxy host created or found successfully" -ForegroundColor Green
    } else {
        Write-Host "Failed to create OpenEMR proxy host" -ForegroundColor Red
    }
    
    # Telehealth Frontend
    $telehealthResponse = New-ProxyHost -Token $token -DomainNames @($envConfig.Domains.telehealth) -ForwardHost "$baseProjectName-telehealth-web-1" -ForwardPort $envConfig.NpmPorts.http -BlockExploits $true -AllowWebsocket $false -ForceSSL $true -HTTP2Support $true -certificate_id $certId -Force:$Force
    if ($telehealthResponse) {
        Write-Host "Telehealth Frontend proxy host created or found successfully" -ForegroundColor Green
    } else {
        Write-Host "Failed to create Telehealth Frontend proxy host" -ForegroundColor Red
    }
    
    # Jitsi Backend
    $jitsiResponse = New-ProxyHost -Token $token -DomainNames @($envConfig.Domains.jitsi) -ForwardHost $JitsiContainer -ForwardPort $envConfig.NpmPorts.http -BlockExploits $true -AllowWebsocket $true -ForceSSL $true -HTTP2Support $true -certificate_id $certId -Force:$Force
    if ($jitsiResponse) {
        Write-Host "Jitsi Backend proxy host created or found successfully" -ForegroundColor Green
    } else {
        Write-Host "Failed to create Jitsi Backend proxy host" -ForegroundColor Red
    }
    
    # Fix NPM network connections
    Fix-NpmNetwork -Environment $Environment -ProjectName $Project
    
    # Check for WordPress container and connect it to NPM proxy network if it exists
    $WordPressContainer = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*$baseProjectName-wordpress*" -or $_ -like "*wordpress*" 
    } | Select-Object -First 1
    
    if ($WordPressContainer) {
        Write-Host "Detected WordPress container: $WordPressContainer" -ForegroundColor Cyan
        
        # Get network configuration
        $networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase
        
        # Connect WordPress container directly to proxy network (not frontend) for better isolation
        $proxyNetwork = $networkConfig.ProxyNetwork
        $isConnected = docker network inspect $proxyNetwork --format '{{range .Containers}}{{.Name}} {{end}}' | Select-String -Pattern $WordPressContainer
        
        if (-not $isConnected) {
            Write-Host "Connecting WordPress container to proxy network..." -ForegroundColor Yellow
            # Check if network exists first to avoid errors
            $networkExists = docker network ls --format "{{.Name}}" | Select-String -Pattern $proxyNetwork
            if (-not $networkExists) {
                docker network create $proxyNetwork 2>$null
            }
            docker network connect $proxyNetwork $WordPressContainer
            Write-Host "Connected WordPress container to proxy network" -ForegroundColor Green
        } else {
            Write-Host "WordPress container already connected to proxy network" -ForegroundColor Green
        }
    } else {
        Write-Host "No WordPress container detected" -ForegroundColor Yellow
    }
} else {
    Write-Host "Creating proxy hosts for production environment..." -ForegroundColor Cyan
}    

Write-Host "" -ForegroundColor Green
Write-Host "Nginx Proxy Manager configuration complete!" -ForegroundColor Green

Write-Host "Configuration complete. You can access the following services:" -ForegroundColor Green

if ($envConfig) {
    Write-Host "  - OpenEMR at https://$($envConfig.Domains.openemr)" -ForegroundColor Cyan
    Write-Host "  - Telehealth Frontend at https://$($envConfig.Domains.telehealth)/videoconsultation" -ForegroundColor Cyan
    Write-Host "  - Jitsi Backend at https://$($envConfig.Domains.jitsi)" -ForegroundColor Cyan
    Write-Host "  - Nginx Proxy Manager Admin at http://localhost:$($envConfig.NpmPorts.admin)" -ForegroundColor Cyan
    
    # Add WordPress URL if the container was detected
    if ($WordPressContainer -and $envConfig.Domains.PSObject.Properties.Name -contains "wordpress") {
        Write-Host "  - WordPress at https://$($envConfig.Domains.wordpress)" -ForegroundColor Cyan
    }
} else {
    Write-Host "  - OpenEMR at https://localhost" -ForegroundColor Cyan
    Write-Host "  - Telehealth Frontend at https://vc.localhost/videoconsultation" -ForegroundColor Cyan
    Write-Host "  - Jitsi Backend at https://vcbknd.localhost" -ForegroundColor Cyan
    Write-Host "  - Nginx Proxy Manager Admin at http://localhost:81" -ForegroundColor Cyan
    
    # Add WordPress URL if the container was detected
    if ($WordPressContainer) {
        Write-Host "  - WordPress at http://localhost:33080" -ForegroundColor Cyan
    }
}

Write-Host "" -ForegroundColor Green
Write-Host "Don't forget to add these domains to your hosts file if needed." -ForegroundColor Yellow

function Get-Container {
    param (
        [string]$ComponentPattern,
        [string]$Suffix = ""
    )
    
    # Try to find the container
    $container = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*$ComponentPattern*" -and ($Suffix -eq "" -or $_ -like "*$Suffix")
    } | Select-Object -First 1
    
    if ($container) {
        Write-Host "Found container: $container" -ForegroundColor Green
        return $container
    } else {
        Write-Host "Container not found with pattern: $ComponentPattern" -ForegroundColor Red
        return $null
    }
}

# Detect NPM container and fix network connections
if ($Environment) {
    Fix-NpmNetwork -Environment $Environment -ProjectName $Project
}

# Function to connect WordPress container to proxy network for isolation
function Connect-WordPressToProxyNetwork {
    param (
        [string]$Environment,
        [string]$Project,
        [string]$DomainBase
    )
    
    # Find WordPress container - use various patterns to ensure we find it
    $baseProjectName = "$Project-$Environment"
    $WordPressContainer = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*$baseProjectName-wordpress*" -or 
        $_ -like "*$Project-wordpress*" -or 
        $_ -like "*wordpress*" 
    } | Select-Object -First 1
    
    if ($WordPressContainer) {
        Write-Host "Detected WordPress container: $WordPressContainer" -ForegroundColor Cyan
        
        # Get the proxy network name directly without calling network-setup.ps1 again
        # This avoids the environment name duplication issue
        $proxyNetwork = "proxy-$Project-$Environment"
        Write-Host "Using proxy network: $proxyNetwork" -ForegroundColor Cyan
        
        # Check if WordPress container is already connected to proxy network
        $isConnected = docker network inspect $proxyNetwork --format '{{range .Containers}}{{.Name}} {{end}}' 2>$null | Select-String -Pattern $WordPressContainer
        
        if (-not $isConnected) {
            Write-Host "Connecting WordPress container to proxy network..." -ForegroundColor Yellow
            # Create the network if it doesn't exist (will silently continue if it exists)
            # Check if network exists first to avoid errors
            $networkExists = docker network ls --format "{{.Name}}" | Select-String -Pattern $proxyNetwork
            if (-not $networkExists) {
                docker network create $proxyNetwork 2>$null
            }
            # Connect the WordPress container to the proxy network
            docker network connect $proxyNetwork $WordPressContainer
            Write-Host "Connected WordPress container to proxy network" -ForegroundColor Green
        } else {
            Write-Host "WordPress container already connected to proxy network" -ForegroundColor Green
        }
        
        return $WordPressContainer
    } else {
        Write-Host "No WordPress container detected" -ForegroundColor Yellow
        return $null
    }
}

# Connect WordPress container to proxy network if it exists
$WordPressContainer = Connect-WordPressToProxyNetwork -Environment $Environment -Project $Project -DomainBase $DomainBase
