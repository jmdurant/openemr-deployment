# Script to fix Docker network connections according to the desired architecture
param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$Project = "aiotp",
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",
    [string]$DomainBase = "localhost"
)

# Get environment and network config
$networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $Project -SourceReposDir $SourceReposDir -DomainBase $DomainBase

# Get network names from configuration
$frontendNetwork = $networkConfig.FrontendNetwork
$sharedNetwork = $networkConfig.SharedNetwork
$baseProjectName = $networkConfig.BaseProjectName

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Docker Network Optimization and Connection Cleanup Tool" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor Cyan 
Write-Host "Project: $Project" -ForegroundColor Cyan
Write-Host "Base Project Name: $baseProjectName" -ForegroundColor Cyan
Write-Host "Main Frontend Network: $frontendNetwork" -ForegroundColor Cyan
Write-Host "Shared Network: $sharedNetwork" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Step 1: Identify all running containers for this environment
Write-Host "`nStep 1: Identifying running containers..." -ForegroundColor Green
$allContainers = docker ps --format "{{.Names}}"
$projectContainers = $allContainers | Where-Object { $_ -match $baseProjectName }

if (-not $projectContainers) {
    Write-Host "No containers found for $baseProjectName" -ForegroundColor Red
    exit 1
}

Write-Host "Found the following containers:" -ForegroundColor Yellow
$projectContainers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

# Step 2: Categorize containers by component
Write-Host "`nStep 2: Categorizing containers..." -ForegroundColor Green

$components = @{
    "openemr" = @{
        containers = $projectContainers | Where-Object { $_ -match "openemr" }
        networks = @($frontendNetwork)
        component_networks = @($baseProjectName + "-openemr_default")
    }
    "telehealth" = @{
        containers = $projectContainers | Where-Object { $_ -match "telehealth" }
        networks = @($frontendNetwork)
        component_networks = @($baseProjectName + "-telehealth_default")
    }
    "proxy" = @{
        containers = $projectContainers | Where-Object { $_ -match "proxy" }
        networks = @($frontendNetwork)
        component_networks = @($baseProjectName + "-proxy_default")
    }
    "jitsi" = @{
        containers = $projectContainers | Where-Object { $_ -match "jitsi" }
        networks = @($sharedNetwork)
        component_networks = @("meet.jitsi")
    }
}

# Step 3: Get current network connections for each container
Write-Host "`nStep 3: Checking current network connections..." -ForegroundColor Green

$containerNetworks = @{}
foreach ($container in $projectContainers) {
    $networkInfo = docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' $container
    $containerNetworks[$container] = $networkInfo -split ' ' | Where-Object { $_ }
    
    Write-Host "Container: $container" -ForegroundColor Yellow
    Write-Host "  Connected to networks: $($containerNetworks[$container] -join ', ')" -ForegroundColor Gray
}

# Step 4: Calculate required networks
Write-Host "`nStep 4: Calculating required networks for each container..." -ForegroundColor Green

$requiredNetworks = @{}
foreach ($component in $components.Keys) {
    foreach ($container in $components[$component].containers) {
        # Start with required networks for this component
        $required = @() + $components[$component].networks
        
        # Add component-specific networks if they exist
        foreach ($compNet in $components[$component].component_networks) {
            $networkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $compNet }
            if ($networkExists) {
                $required += $compNet
            }
        }
        
        # Special case: Add shared network for all components except jitsi
        # (Jitsi already has shared network in its main networks list)
        if ($component -ne "jitsi") {
            $required += $sharedNetwork
        }
        
        # Store the calculated required networks
        $requiredNetworks[$container] = $required
        
        Write-Host "Container: $container" -ForegroundColor Yellow
        Write-Host "  Required networks: $($required -join ', ')" -ForegroundColor Gray
    }
}

# Step 5: Disconnect from unnecessary networks and connect to required ones
Write-Host "`nStep 5: Optimizing network connections..." -ForegroundColor Green

foreach ($container in $projectContainers) {
    $current = $containerNetworks[$container]
    $required = $requiredNetworks[$container]
    
    # Find networks to disconnect (in current but not in required)
    $toDisconnect = $current | Where-Object { $required -notcontains $_ }
    
    # Find networks to connect (in required but not in current)
    $toConnect = $required | Where-Object { $current -notcontains $_ }
    
    Write-Host "Container: $container" -ForegroundColor Yellow
    
    # Disconnect from unnecessary networks
    foreach ($network in $toDisconnect) {
        # Skip the "bridge" network which is the default network
        if ($network -eq "bridge") {
            continue
        }
        
        Write-Host "  Disconnecting from: $network" -ForegroundColor Red
        docker network disconnect $network $container
    }
    
    # Connect to required networks
    foreach ($network in $toConnect) {
        Write-Host "  Connecting to: $network" -ForegroundColor Green
        
        # Ensure the network exists before trying to connect
        $networkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $network }
        if (-not $networkExists) {
            Write-Host "    Creating network: $network" -ForegroundColor Yellow
            docker network create $network
        }
        
        docker network connect $network $container
    }
}

# Step 6: Verify the results
Write-Host "`nStep 6: Verifying network connections..." -ForegroundColor Green

foreach ($container in $projectContainers) {
    $networkInfo = docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' $container
    $currentNetworks = $networkInfo -split ' ' | Where-Object { $_ }
    
    Write-Host "Container: $container" -ForegroundColor Yellow
    Write-Host "  Connected to networks: $($currentNetworks -join ', ')" -ForegroundColor Gray
}

Write-Host "`nNetwork optimization complete!" -ForegroundColor Green
Write-Host "The container network architecture now follows the simplified design." -ForegroundColor Green
