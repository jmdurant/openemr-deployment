param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$Project = "aiotp",
    [string]$DomainBase = "localhost"
)

# Get environment configuration
$networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase

# Get network names from environment config
$frontendNetwork = $networkConfig.FrontendNetwork
$sharedNetwork = $networkConfig.SharedNetwork

# Define the expected container name
$baseProjectName = $networkConfig.BaseProjectName
$npmContainer = "$baseProjectName-proxy-proxy-1"

Write-Host "Configuring networks for NPM in $Environment environment" -ForegroundColor Cyan
Write-Host "Looking for NPM container: $npmContainer" -ForegroundColor Yellow

# Check if the container exists
$containerExists = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $npmContainer }

if (-not $containerExists) {
    Write-Host "ERROR: NPM container $npmContainer not found" -ForegroundColor Red
    Write-Host "Please ensure the proxy service is running for project $Project" -ForegroundColor Yellow
    exit 1
}

Write-Host "Found NPM container: $npmContainer" -ForegroundColor Green

# Function to ensure container is connected to a network
function Connect-ContainerToNetwork {
    param (
        [string]$NetworkName,
        [string]$ContainerName
    )
    
    Write-Host "Checking $NetworkName network..." -ForegroundColor Yellow
    
    # Create network if it doesn't exist
    $networkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $NetworkName }
    if (-not $networkExists) {
        Write-Host "Creating network: $NetworkName" -ForegroundColor Yellow
        docker network create $NetworkName
    }
    
    # Check if container is connected
    $isConnected = docker network inspect $NetworkName --format "{{range .Containers}}{{.Name}} {{end}}" | Select-String -Pattern $ContainerName
    
    if (-not $isConnected) {
        Write-Host "Connecting $ContainerName to $NetworkName..." -ForegroundColor Yellow
        docker network connect $NetworkName $ContainerName
        Write-Host "Successfully connected to $NetworkName" -ForegroundColor Green
    } else {
        Write-Host "$ContainerName is already connected to $NetworkName" -ForegroundColor Green
    }
}

# Connect to required networks according to the simplified architecture
Connect-ContainerToNetwork -NetworkName $frontendNetwork -ContainerName $npmContainer
Connect-ContainerToNetwork -NetworkName $sharedNetwork -ContainerName $npmContainer

# Get component-specific network
$npmDefaultNetwork = "$baseProjectName-proxy_default"
Connect-ContainerToNetwork -NetworkName $npmDefaultNetwork -ContainerName $npmContainer

# Clean up generic networks at the end
Write-Host "Cleaning up generic networks..." -ForegroundColor Yellow

# Define the networks to clean up
$networksToClean = @(
    "frontend",
    "proxy_default"
)

foreach ($network in $networksToClean) {
    Write-Host "Cleaning up $network network..." -ForegroundColor Yellow
    
    # Get all containers connected to this network using ConvertFrom-Json
    $networkInfo = docker network inspect $network | ConvertFrom-Json
    $containers = $networkInfo.Containers.PSObject.Properties.Value.Name
    
    if ($containers) {
        Write-Host "Disconnecting containers from $network..." -ForegroundColor Yellow
        foreach ($container in $containers) {
            if ($container.Trim()) {
                try {
                    Write-Host "Disconnecting $container from $network..." -ForegroundColor Yellow
                    docker network disconnect -f $network $container 2>$null
                    Write-Host "Successfully disconnected $container from $network" -ForegroundColor Green
                } catch {
                    Write-Host ("Could not disconnect {0} from {1}: {2}" -f $container, $network, $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    }
    
    # Try to remove the network
    try {
        Write-Host "Removing $network network..." -ForegroundColor Yellow
        docker network rm $network
        Write-Host "Successfully removed $network network" -ForegroundColor Green
    } catch {
        Write-Host ("Could not remove {0} network: {1}" -f $network, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host "Network cleanup complete" -ForegroundColor Green


Write-Host "NPM network configuration complete!" -ForegroundColor Green
Write-Host "NPM is now connected to both the main frontend network and the shared network." -ForegroundColor Green
Write-Host "This ensures it can communicate with all services while maintaining the simplified architecture." -ForegroundColor Green
