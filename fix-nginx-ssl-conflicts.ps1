# Script to fix Nginx Proxy Manager SSL conflicts with localhost
param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$Project = "aiotp",  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
    [string]$ProxyAppContainerPattern = "proxy",
    [switch]$StagingEnvironment = $false,  # Keep for backward compatibility
    [switch]$Force = $true,
    [switch]$SkipCertGeneration = $false,
    [switch]$RestartContainer = $true,
    [string]$SourceReposDir = "$PSScriptRoot\source-repos"
)

# Handle backward compatibility with -StagingEnvironment switch
if ($StagingEnvironment -and -not $Environment) {
    $Environment = "staging"
}

# Load environment configuration
$envConfig = & "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project
if (-not $envConfig) {
    Write-Error "Failed to load environment configuration"
    exit 1
}

Write-Host "Loaded configuration for environment: $Environment" -ForegroundColor Green

# Get domains from environment config
$domains = @{
    "openemr" = $envConfig.Domains.openemr
    "telehealth" = $envConfig.Domains.telehealth
    "jitsi" = $envConfig.Domains.jitsi
}

# Validate domains
$validDomains = @{}
foreach ($key in $domains.Keys) {
    $domain = $domains[$key]
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        $validDomains[$key] = $domain
    }
}

if ($validDomains.Count -eq 0) {
    Write-Host "No valid domains found in configuration. Please check your environment configuration." -ForegroundColor Red
    exit 1
}

Write-Host "Found the following domains:" -ForegroundColor Green
foreach ($key in $validDomains.Keys) {
    Write-Host "- $key : $($validDomains[$key])" -ForegroundColor Green
}

# Find the NPM container
Write-Host "Searching for NPM container..." -ForegroundColor Yellow
$proxyAppContainer = $null

# Check for container with proxy in the name
Write-Host "Checking for container matching pattern: $ProxyAppContainerPattern" -ForegroundColor Yellow
$containers = docker ps --format "{{.Names}}" | Where-Object { $_ -match $ProxyAppContainerPattern }

if ($containers) {
    # If multiple containers found, use the first one
    $proxyAppContainer = $containers | Select-Object -First 1
    Write-Host "Found NPM container: $proxyAppContainer" -ForegroundColor Green
} else {
    Write-Host "No containers matching pattern '$ProxyAppContainerPattern' found." -ForegroundColor Red
    Write-Host "Make sure the Nginx Proxy Manager container is running." -ForegroundColor Yellow
    exit 1
}

# Check for SSL certificates
$certPath = Join-Path $PSScriptRoot "ssl\$Project\$Environment\fullchain.pem"
$keyPath = Join-Path $PSScriptRoot "ssl\$Project\$Environment\privkey.pem"

Write-Host "Checking for SSL certificates..."
if (-not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
    Write-Host "SSL certificates not found at expected locations:" -ForegroundColor Red
    Write-Host "  Certificate: $certPath" -ForegroundColor Yellow
    Write-Host "  Private Key: $keyPath" -ForegroundColor Yellow
    
    if (-not $SkipCertGeneration) {
        Write-Host "Generating certificates using generate-certs.ps1..." -ForegroundColor Yellow
        
        # Call generate-certs.ps1 with proper parameters
        & "$PSScriptRoot\generate-certs.ps1" -Environment $Environment -Project $Project
        
        # Check if certificates were generated successfully
        if (-not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
            Write-Host "Failed to generate certificates. Please run generate-certs.ps1 manually." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "Skipping certificate generation as requested. Please run generate-certs.ps1 manually." -ForegroundColor Yellow
        exit 1
    }
}

# Create data directory for NPM if it doesn't exist
$npmDataDir = Join-Path -Path $PSScriptRoot -ChildPath "$Project-$Environment\proxy\data"
if (-not (Test-Path -Path $npmDataDir)) {
    Write-Host "NPM data directory not found at: $npmDataDir" -ForegroundColor Yellow
    Write-Host "Make sure the Nginx Proxy Manager is properly set up." -ForegroundColor Yellow
    exit 1
}

# Create SSL directory in NPM data directory
$npmSslDir = Join-Path -Path $npmDataDir -ChildPath "ssl"
if (-not (Test-Path -Path $npmSslDir)) {
    New-Item -Path $npmSslDir -ItemType Directory -Force | Out-Null
    Write-Host "Created SSL directory in NPM data directory: $npmSslDir" -ForegroundColor Green
}

# Copy certificates to NPM data directory
foreach ($domain in $validDomains.Values) {
    $domainSslDir = Join-Path -Path $npmSslDir -ChildPath $domain
    if (-not (Test-Path -Path $domainSslDir)) {
        New-Item -Path $domainSslDir -ItemType Directory -Force | Out-Null
        Write-Host "Created SSL directory for domain $domain`: $domainSslDir" -ForegroundColor Green
    }
    
    # Copy certificate and key
    Copy-Item -Path $certPath -Destination "$domainSslDir\fullchain.pem" -Force
    Copy-Item -Path $keyPath -Destination "$domainSslDir\privkey.pem" -Force
    
    Write-Host "Copied certificates for domain $domain`:" -ForegroundColor Green
    Write-Host "  $certPath -> $domainSslDir\fullchain.pem" -ForegroundColor Green
    Write-Host "  $keyPath -> $domainSslDir\privkey.pem" -ForegroundColor Green
}

# Clean up localhost configuration for production environment
if ($Environment -eq "production") {
    Write-Host "Cleaning up localhost SSL configuration for production..." -ForegroundColor Yellow
    
    # Remove blocking directives from default.conf
    docker exec $proxyAppContainer sed -i 's/ssl_reject_handshake on;//g' /etc/nginx/conf.d/default.conf
    docker exec $proxyAppContainer sed -i 's/return 444;//g' /etc/nginx/conf.d/default.conf
    
    #fixes the SSL certificate configuration in /etc/nginx/conf.d/default.conf
    docker exec $proxyAppContainer sed -i 's/listen \[\:\:\]\:443 ssl\;/listen \[\:\:\]\:443 ssl\;\n        ssl_certificate \/data\/custom_ssl\/npm-1\/fullchain.pem\;\n        ssl_certificate_key \/data\/custom_ssl\/npm-1\/privkey.pem\;/g' /etc/nginx/conf.d/default.conf
    
    #Remove default server block for port 443
    docker exec $proxyAppContainer sed -i '/# First 443 Host/,/}/d' /etc/nginx/conf.d/default.conf
    # Remove any duplicate localhost server blocks
    docker exec $proxyAppContainer sh -c 'rm -f /etc/nginx/conf.d/localhost.conf'

    #Make proxy host the default server for HTTPS:
    #docker exec $Project-$Environment-proxy-proxy-1 sed -i 's/listen 443 ssl;/listen 443 ssl default_server;/g' /data/nginx/proxy_host/1.conf
    docker exec $proxyAppContainer sed -i 's/listen \[\:\:\]\:443 ssl;/listen \[\:\:\]\:443 ssl default_server;/g' /data/nginx/proxy_host/1.conf
    #fix NPM openemr
    #docker exec $proxyAppContainer sed -i 's/$Project-$Environment-openemr-openemr-1:30080/$Project-$Environment-openemr-openemr-1:80/g' /data/nginx/proxy_host/1.conf
    
    Write-Host "Localhost SSL configuration cleaned up." -ForegroundColor Green
}

# Restart the Nginx Proxy Manager container to apply changes
if ($RestartContainer) {
    Write-Host "Restarting Nginx Proxy Manager container..." -ForegroundColor Yellow
    docker restart $proxyAppContainer
    Write-Host "Nginx Proxy Manager container restarted." -ForegroundColor Green
} else {
    Write-Host "Skipping container restart as requested." -ForegroundColor Yellow
}

Write-Host "SSL configuration for Nginx Proxy Manager completed." -ForegroundColor Green
Write-Host "You can now configure SSL certificates in the NPM admin interface." -ForegroundColor Green
Write-Host "The certificates are available in the NPM data directory at: $npmSslDir" -ForegroundColor Green
