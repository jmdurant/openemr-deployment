# Fix Network Connections Script
# This script ensures that containers are connected to the appropriate networks

param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [switch]$StagingEnvironment = $false,  # Keep for backward compatibility
    [Parameter()]
    [string]$Component = "all",
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",  # Path to source repositories
    [string]$Project = "aiotp",  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
    [string]$DomainBase = "localhost"  # Default domain base is "localhost"
)

# Use the network setup script to ensure consistent network naming
# This will create networks if they don't exist
$networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -StagingEnvironment:$StagingEnvironment -SourceReposDir $SourceReposDir -Project $Project -DomainBase $DomainBase

# Get network and project names from the network configuration
$baseProjectName = $networkConfig.BaseProjectName
$frontendNetwork = $networkConfig.FrontendNetwork
$proxyNetwork = $networkConfig.ProxyNetwork

Write-Host "Fixing network connections for $baseProjectName environment ($Component component)..." -ForegroundColor Yellow

# Networks should already be created by network-setup.ps1, but verify they exist
Write-Host "Verifying networks exist..." -ForegroundColor Yellow
$frontendExists = docker network ls | Select-String $frontendNetwork
$proxyDefaultExists = docker network ls | Select-String $proxyNetwork

if (-not $frontendExists -or -not $proxyDefaultExists) {
    Write-Host "Networks are missing. Please run network-setup.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "$frontendNetwork network exists " -ForegroundColor Green
Write-Host "$proxyNetwork network exists " -ForegroundColor Green

# Define folder names for each component
$openemrFolder = "openemr"
$telehealthFolder = "telehealth"
$jitsiFolder = "jitsi-docker"
$proxyFolder = "proxy"

# Define container patterns for each component based on project type
if ($Project -eq "official") {
    # The official project has a different container naming pattern
    $openemrContainerPattern = "$baseProjectName-openemr-1"
} else {
    # Standard naming pattern for other projects
    $openemrContainerPattern = "$baseProjectName-$openemrFolder-$openemrFolder-1"
}

$telehealthAppContainerPattern = "$baseProjectName-$telehealthFolder-app-1"
$telehealthWebContainerPattern = "$baseProjectName-$telehealthFolder-web-1"
$telehealthDbContainerPattern = "$baseProjectName-$telehealthFolder-database-1"
$jitsiWebContainerPattern = "$baseProjectName-$jitsiFolder-web-1"
$jitsiJvbContainerPattern = "$baseProjectName-$jitsiFolder-jvb-1"
$proxyContainerPattern = "$baseProjectName-$proxyFolder-proxy-1"

# Function to get shared Jitsi container
function Get-SharedJitsiContainer {
    # Try to find the shared Jitsi container
    $container = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*jitsi-docker*" -and $_ -like "*web-1" 
    } | Select-Object -First 1
    
    return $container
}

# Function to get environment-specific Jitsi container
function Get-EnvironmentJitsiContainer {
    param (
        [string]$ProjectName
    )
    
    # Try to find environment-specific Jitsi container
    $container = docker ps --format "{{.Names}}" | Where-Object { 
        $_ -like "*$ProjectName-jitsi*" -and $_ -like "*web-1" 
    } | Select-Object -First 1
    
    return $container
}

# Function to connect container to network if not already connected
function Connect-ContainerToNetwork {
    param (
        [string]$ContainerPattern,
        [string]$Network,
        [string]$Description,
        [bool]$IsSharedJitsi = $false
    )
    
    $container = if ($IsSharedJitsi) {
        Get-SharedJitsiContainer
    } else {
        docker ps --format "{{.Names}}" | Where-Object { $_ -match $ContainerPattern } | Select-Object -First 1
    }
    
    if ($container) {
        Write-Host "Found $Description container: $container" -ForegroundColor Green
        
        # Check if container is already connected to the network
        $networkInfo = docker network inspect $Network --format '{{range .Containers}}{{.Name}} {{end}}'
        if ($networkInfo -match $container) {
            Write-Host "$container is already connected to $Network" -ForegroundColor Green
        } else {
            Write-Host "Connecting $container to $Network..." -ForegroundColor Yellow
            docker network connect $Network $container
            Write-Host "Connected $container to $Network" -ForegroundColor Green
        }
    } else {
        Write-Host "$Description container not found with pattern: $ContainerPattern" -ForegroundColor Red
    }
}

# Create and connect to non-environment-specific networks
Write-Host "Checking for non-environment-specific networks..." -ForegroundColor Yellow

# Define generic network names that might be referenced in docker-compose files
$genericNetworks = @{
    "frontend" = "Frontend network"
    "proxy_default" = "Proxy default network"
    "$Project-shared-network" = "Shared network for Jitsi"
}

foreach ($network in $genericNetworks.Keys) {
    # Create the network if it doesn't exist
    Write-Host "Ensuring $($genericNetworks[$network]) ($network) exists..." -ForegroundColor Yellow
    docker network create $network 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$network network already exists" -ForegroundColor Yellow
    } else {
        Write-Host "Created $network network" -ForegroundColor Green
    }
}

# Connect containers to networks based on the specified component
Write-Host "Connecting containers to networks..." -ForegroundColor Yellow

if ($Component -eq "all" -or $Component -eq "openemr") {
    # Connect OpenEMR container to frontend network
    Connect-ContainerToNetwork -ContainerPattern $openemrContainerPattern -Network $frontendNetwork -Description "OpenEMR"
    
    # Connect OpenEMR container to generic networks
    foreach ($network in $genericNetworks.Keys) {
        Connect-ContainerToNetwork -ContainerPattern $openemrContainerPattern -Network $network -Description "OpenEMR"
    }
}

if ($Component -eq "all" -or $Component -eq "telehealth") {
    # Connect Telehealth App container to frontend network
    Connect-ContainerToNetwork -ContainerPattern $telehealthAppContainerPattern -Network $frontendNetwork -Description "Telehealth App"
    
    # Connect Telehealth Web container to frontend network
    Connect-ContainerToNetwork -ContainerPattern $telehealthWebContainerPattern -Network $frontendNetwork -Description "Telehealth Web"
    
    # Connect Telehealth DB container to frontend network
    Connect-ContainerToNetwork -ContainerPattern $telehealthDbContainerPattern -Network $frontendNetwork -Description "Telehealth DB"
    
    # Connect Telehealth containers to generic networks
    foreach ($network in $genericNetworks.Keys) {
        Connect-ContainerToNetwork -ContainerPattern $telehealthAppContainerPattern -Network $network -Description "Telehealth App"
        Connect-ContainerToNetwork -ContainerPattern $telehealthWebContainerPattern -Network $network -Description "Telehealth Web"
        Connect-ContainerToNetwork -ContainerPattern $telehealthDbContainerPattern -Network $network -Description "Telehealth DB"
    }
}

if ($Component -eq "all" -or $Component -eq "jitsi") {
    # First try to connect shared Jitsi container
    $sharedJitsiContainer = Get-SharedJitsiContainer
    if ($sharedJitsiContainer) {
        Write-Host "Found shared Jitsi container: $sharedJitsiContainer" -ForegroundColor Green
        Connect-ContainerToNetwork -ContainerPattern "" -Network "$Project-shared-network" -Description "Shared Jitsi" -IsSharedJitsi $true
    }
    
    # Then try to connect environment-specific Jitsi containers
    $envJitsiContainer = Get-EnvironmentJitsiContainer -ProjectName $baseProjectName
    if ($envJitsiContainer) {
        Write-Host "Found environment-specific Jitsi container: $envJitsiContainer" -ForegroundColor Green
        # Connect to both frontend and shared networks
        Connect-ContainerToNetwork -ContainerPattern $jitsiWebContainerPattern -Network $frontendNetwork -Description "Environment-specific Jitsi Web"
        Connect-ContainerToNetwork -ContainerPattern $jitsiJvbContainerPattern -Network $frontendNetwork -Description "Environment-specific Jitsi JVB"
        Connect-ContainerToNetwork -ContainerPattern $jitsiWebContainerPattern -Network "$Project-shared-network" -Description "Environment-specific Jitsi Web"
        Connect-ContainerToNetwork -ContainerPattern $jitsiJvbContainerPattern -Network "$Project-shared-network" -Description "Environment-specific Jitsi JVB"
    }
}

if ($Component -eq "all" -or $Component -eq "proxy") {
    # Connect Proxy container to frontend network
    Connect-ContainerToNetwork -ContainerPattern $proxyContainerPattern -Network $frontendNetwork -Description "Nginx Proxy Manager"
    
    # Connect Proxy container to generic networks
    foreach ($network in $genericNetworks.Keys) {
        Connect-ContainerToNetwork -ContainerPattern $proxyContainerPattern -Network $network -Description "Nginx Proxy Manager"
    }
}

# Verify connections
Write-Host "Verifying network connections..." -ForegroundColor Yellow
docker network inspect $frontendNetwork --format '{{range .Containers}}{{.Name}} {{end}}'

Write-Host "Network connections fixed successfully!" -ForegroundColor Green
