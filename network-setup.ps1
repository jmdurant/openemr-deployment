# Network Setup Script for AIO Telehealth Platform
# This script creates and manages Docker networks for different environments

param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [switch]$StagingEnvironment = $false,  # Keep for backward compatibility
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",  # Path to source repositories
    [string]$Project = "aiotp",  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
    [string]$DomainBase = "localhost"  # Default domain base is "localhost", can be overridden with custom domains
)

# Handle backward compatibility with -StagingEnvironment switch
if ($StagingEnvironment -and -not $Environment) {
    $Environment = "staging"
}

# Set network names based on environment
# Main integration network - all components connect here
$frontendNetwork = "frontend-$Project-$Environment"
# Shared network for Jitsi and cross-environment resources
$sharedNetwork = "$Project-shared-network"
# Meet.jitsi network for Jitsi internal communication
$meetJitsiNetwork = "meet.jitsi"

# Set project name based on environment and project
$baseProjectName = "$Project-$Environment"

Write-Host "Setting up networks for $baseProjectName environment..." -ForegroundColor Yellow

# Create meet.jitsi network if it doesn't exist (this is a Jitsi-specific internal network)
Write-Host "Ensuring meet.jitsi network ($meetJitsiNetwork) exists..." -ForegroundColor Yellow
$meetJitsiExists = docker network ls --format "{{.Name}}" | Select-String $meetJitsiNetwork
if (-not $meetJitsiExists) {
    Write-Host "Creating $meetJitsiNetwork network..." -ForegroundColor Yellow
    docker network create --internal $meetJitsiNetwork
    Write-Host "Created $meetJitsiNetwork network" -ForegroundColor Green
} else {
    Write-Host "$meetJitsiNetwork network already exists" -ForegroundColor Green
}

# Create shared network if it doesn't exist
Write-Host "Ensuring shared network ($sharedNetwork) exists..." -ForegroundColor Yellow
$sharedExists = docker network ls --format "{{.Name}}" | Select-String $sharedNetwork
if (-not $sharedExists) {
    Write-Host "Creating $sharedNetwork network..." -ForegroundColor Yellow
    docker network create $sharedNetwork
    Write-Host "Created $sharedNetwork network" -ForegroundColor Green
} else {
    Write-Host "$sharedNetwork network already exists" -ForegroundColor Green
}

# Create main frontend network if it doesn't exist
Write-Host "Ensuring main frontend network ($frontendNetwork) exists..." -ForegroundColor Yellow
$frontendExists = docker network ls --format "{{.Name}}" | Select-String $frontendNetwork
if (-not $frontendExists) {
    Write-Host "Creating $frontendNetwork network..." -ForegroundColor Yellow
    docker network create $frontendNetwork
    Write-Host "Created $frontendNetwork network" -ForegroundColor Green
} else {
    Write-Host "$frontendNetwork network already exists" -ForegroundColor Green
}

# Export network names for other scripts to use
$env:FRONTEND_NETWORK = $frontendNetwork
$env:SHARED_NETWORK = $sharedNetwork
$env:MEET_JITSI_NETWORK = $meetJitsiNetwork
$env:BASE_PROJECT_NAME = $baseProjectName

# For backward compatibility, also set traditional proxy network
$proxyNetwork = "proxy-$Project-$Environment"
$env:PROXY_NETWORK = $proxyNetwork

# Return network information as an object to make it easier for other scripts to use
return @{
    FrontendNetwork = $frontendNetwork
    SharedNetwork = $sharedNetwork
    MeetJitsiNetwork = $meetJitsiNetwork
    BaseProjectName = $baseProjectName
    Environment = $Environment
    # Keep for backward compatibility
    ProxyNetwork = $proxyNetwork
}

Write-Host "Network setup complete!" -ForegroundColor Green
