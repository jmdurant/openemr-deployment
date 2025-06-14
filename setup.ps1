# All-In-One Telehealth Platform Setup Script

param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$Project = "aiotp",
    [string]$OpenEmrFolder = "openemr",
    [string]$TelehealthFolder = "telehealth",
    [string]$ProxyFolder = "proxy",
    [string]$JitsiFolder = "jitsi-docker",
    [switch]$SkipCertificateGeneration = $false,
    [switch]$SkipNpmConfiguration = $false,
    [switch]$SkipHostsCheck = $false,
    [switch]$NonInteractive = $false,
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",
    [Parameter(Mandatory=$false)]
    [bool]$SkipBackup = $false,
    [string]$DomainBase = "localhost",
    [switch]$Force,
    [switch]$ARM = $false
)

# Parameter Debugging - Show actual values received
Write-Host "====== PARAMETER DEBUG INFO ======" -ForegroundColor Cyan
Write-Host "Environment = '$Environment'" -ForegroundColor Magenta
Write-Host "Project = '$Project'" -ForegroundColor Magenta
Write-Host "DomainBase = '$DomainBase'" -ForegroundColor Magenta
Write-Host "All bound parameters:" -ForegroundColor Magenta
$PSBoundParameters.Keys | ForEach-Object { Write-Host "  $_ = '$($PSBoundParameters[$_])'" -ForegroundColor Magenta }
Write-Host "================================" -ForegroundColor Cyan

# Set base project name based on environment
$baseProjectName = if ($Environment -eq "") { "$Project" } else { "$Project-$Environment" }

# Set DevMode based on environment (true for dev, false otherwise)
$script:DevMode = $Environment -eq "dev"
Write-Host "DevMode is $(if ($script:DevMode) { "enabled" } else { "disabled" }) for $Environment environment" -ForegroundColor $(if ($script:DevMode) { "Green" } else { "Yellow" })
Write-Host "ARM mode is $(if ($ARM) { "enabled" } else { "disabled" })" -ForegroundColor $(if ($ARM) { "Green" } else { "Yellow" })

# Define deployment folder path early to avoid null reference errors
$deploymentFolder = "$Project-$Environment"
$deploymentFolderPath = Join-Path $PSScriptRoot $deploymentFolder
Write-Host "Using deployment folder path: $deploymentFolderPath" -ForegroundColor Cyan

# Function definitions
function Handle-AllVolumes {
    param (
        [string]$ProjectName,
        [bool]$RemoveAll = $false
    )
    
    Write-Host "=== Volume Management ===" -ForegroundColor Cyan
    
    # List all relevant volumes
    $allVolumes = docker volume ls --format "{{.Name}}" | Where-Object { 
        $_ -like "$Project*" -or 
        $_ -like "openemr-telesalud*" -or 
        $_ -like "telehealth*" -or
        $_ -like "$Project*"
    }
    
    if ($allVolumes) {
        Write-Host "Found the following volumes:" -ForegroundColor Yellow
        $allVolumes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        
        # Categorize volumes
        $databaseVolumes = $allVolumes | Where-Object { $_ -like "*database*" -or $_ -like "*mysql*" -or $_ -like "*sql*" }
        $otherVolumes = $allVolumes | Where-Object { $_ -notin $databaseVolumes }
        
        if (-not $RemoveAll) {
            # Ask about database volumes first
            if ($databaseVolumes) {
                Write-Host "`nFound database volumes:" -ForegroundColor Yellow
                $databaseVolumes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                $removeDatabases = Get-UserInput "Do you want to remove database volumes? This will DELETE ALL DATA (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
            }
            
            # Ask about other volumes
            if ($otherVolumes) {
                Write-Host "`nFound other volumes:" -ForegroundColor Yellow
                $otherVolumes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                $removeOthers = Get-UserInput "Do you want to remove other non-database volumes? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
            }
        }
        
        # Handle database volumes
        if ($databaseVolumes -and ($RemoveAll -or $removeDatabases -eq "y")) {
            Write-Host "`nRemoving database volumes..." -ForegroundColor Yellow
            foreach ($volume in $databaseVolumes) {
                # Stop containers using this volume
                $containersUsingVolume = docker ps -a --filter "volume=$volume" --format "{{.Names}}"
                foreach ($container in $containersUsingVolume) {
                    Write-Host "Stopping container using volume $volume`: $container" -ForegroundColor Yellow
                    docker stop $container 2>$null
                    docker rm $container 2>$null
                }
                
                Write-Host "Removing volume: $volume" -ForegroundColor Yellow
                docker volume rm $volume 2>$null
            }
        }
        
        # Handle other volumes
        if ($otherVolumes -and ($RemoveAll -or $removeOthers -eq "y")) {
            Write-Host "`nRemoving other volumes..." -ForegroundColor Yellow
            foreach ($volume in $otherVolumes) {
                # Stop containers using this volume
                $containersUsingVolume = docker ps -a --filter "volume=$volume" --format "{{.Names}}"
                foreach ($container in $containersUsingVolume) {
                    Write-Host "Stopping container using volume $volume`: $container" -ForegroundColor Yellow
                    docker stop $container 2>$null
                    docker rm $container 2>$null
                }
                
                Write-Host "Removing volume: $volume" -ForegroundColor Yellow
                docker volume rm $volume 2>$null
            }
        }
    } else {
        Write-Host "No volumes found for project $ProjectName" -ForegroundColor Green
    }
    
    Write-Host "Volume management complete." -ForegroundColor Green
    Write-Host "===========================" -ForegroundColor Cyan
}

function Remove-ProjectNetworks {
    param (
        [string]$ProjectName,
        [string]$Environment
    )
    Write-Host "Removing project networks..." -ForegroundColor Yellow
    
    # Remove project-specific networks
    $networks = docker network ls --filter "name=$ProjectName" --format "{{.Name}}"
    foreach ($network in $networks) {
        # Disconnect any containers first
        $connectedContainers = docker network inspect $network --format '{{range .Containers}}{{.Name}} {{end}}'
        if ($connectedContainers) {
            foreach ($container in $connectedContainers.Split(' ')) {
                if ($container) {
                    docker network disconnect -f $network $container 2>$null
                }
            }
        }
        docker network rm $network 2>$null
    }
    
    # Handle environment-specific frontend network
    $frontendNetwork = switch ($Environment) {
        "staging" { "frontend-staging" }
        "dev" { "frontend-dev" }
        "test" { "frontend-test" }
        default { "frontend" }
    }
    
    if (docker network ls --filter "name=$frontendNetwork" --format "{{.Name}}") {
        $connectedContainers = docker network inspect $frontendNetwork --format '{{range .Containers}}{{.Name}} {{end}}'
        if ($connectedContainers) {
            foreach ($container in $connectedContainers.Split(' ')) {
                if ($container) {
                    docker network disconnect -f $frontendNetwork $container 2>$null
                }
            }
        }
        docker network rm $frontendNetwork 2>$null
    }
}

function Stop-ProjectComponent {
    param (
        [string]$Name,
        [string]$ProjectName,
        [string]$Environment = ""
    )
    Write-Host "Stopping $Name..." -ForegroundColor Yellow
    
    # Define patterns to match containers
    $patterns = @(
        # Project and environment specific patterns (primary match)
        "^$ProjectName-$Name",
        "^$Project-$Environment-$Name",
        # Component specific patterns with project name
        "$Project.*$Name",
        # Legacy patterns (fallback)
        "^$Name"
    )
    
    # Add component-specific patterns
    switch ($Name.ToLower()) {
        "nginx proxy manager" {
            $patterns += @(
                "^$Project-proxy-",
                "^$ProjectName-proxy-",
                "^proxy-"
            )
        }
        "openemr" {
            $patterns += @(
                "^$Project-$Environment-openemr",
                "^$ProjectName-openemr",
                "^openemr"
            )
        }
        "telehealth" {
            $patterns += @(
                "^$Project-$Environment-telehealth",
                "^$ProjectName-telehealth",
                "^telehealth"
            )
        }
        "jitsi" {
            $patterns += @(
                "^$Project-$Environment-jitsi",
                "^$ProjectName-jitsi",
                "^jitsi"
            )
        }
    }
    
    # Find and stop matching containers
    foreach ($pattern in $patterns) {
        Write-Host "Checking for containers matching pattern: $pattern" -ForegroundColor Yellow
        $containers = docker ps -a --format "{{.Names}}" | Where-Object { $_ -match $pattern }
        
        foreach ($container in $containers) {
            Write-Host "Stopping container: $container" -ForegroundColor Yellow
            docker stop $container 2>$null
            docker rm $container 2>$null
        }
    }
}

function Get-UserInput {
    param (
        [string]$Prompt,
        [string]$ForegroundColor = "Yellow",
        [string[]]$ValidResponses = @(),
        [string]$DefaultResponse = ""
    )
    
    # If Force switch is used, return default without prompting
    # Also respect existing -NonInteractive flag if it was intended for this
    if ($Force -or $NonInteractive) {
        Write-Host "$Prompt [$DefaultResponse] (Auto-selected due to -Force or -NonInteractive flag)" -ForegroundColor $ForegroundColor
        return $DefaultResponse
    }
    
    Write-Host ""
    if ($DefaultResponse -ne "") {
        Write-Host "$Prompt [$DefaultResponse]" -ForegroundColor $ForegroundColor
    } else {
        Write-Host $Prompt -ForegroundColor $ForegroundColor
    }
    
    $input = Read-Host
    
    # Use default if input is empty
    if ($input -eq "" -and $DefaultResponse -ne "") {
        $input = $DefaultResponse
    }
    
    # Validate input if validation is required
    if ($ValidResponses.Count -gt 0 -and $input -ne "") {
        while ($ValidResponses -notcontains $input.ToLower()) {
            Write-Host "Invalid input. Please enter one of: $($ValidResponses -join ', ')" -ForegroundColor Red
            Write-Host $Prompt -ForegroundColor $ForegroundColor
            $input = Read-Host
        }
    }
    
    Write-Host ""
    return $input
}

# Function to test if a script exists in the current directory
function Test-ScriptExists {
    param (
        [string]$ScriptName
    )
    
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $ScriptName
    return Test-Path -Path $scriptPath -PathType Leaf
}

# Define project components
$components = @(
    @{
        Name = "OpenEMR"
        ProjectName = "$baseProjectName-openemr"
    },
    @{
        Name = "OpenEMR-Telesalud"
        ProjectName = "$baseProjectName"
    },
    @{
        Name = "Telehealth"
        ProjectName = "$baseProjectName-telehealth"
    },
    @{
        Name = "Jitsi"
        ProjectName = "$baseProjectName-jitsi-docker"
    },
    @{
        Name = "Nginx Proxy Manager"
        ProjectName = "$baseProjectName-proxy"
    }
)

# Set working directory to the current script location
$workingDirectory = $PSScriptRoot

# Configure environment-specific settings
$environmentConfig = @{
    staging = @{
        dirName = "$Project-staging"
        projectName = "$Project-staging"
        portOffset = 10
        npmPorts = @{
            http = 8081    # 80 + 10*1
            https = 8444   # Special case for backward compatibility
            admin = 8181   # 81 + 10*10
        }
        domains = @{
            openemr = "staging.localhost"
            telehealth = "vc-staging.localhost"
            jitsi = "vcbknd-staging.localhost"
        }
    }
    dev = @{
        dirName = "$Project-dev"
        projectName = "$Project-dev"
        portOffset = 20
        npmPorts = @{
            http = 8082    # 80 + 20*1
            https = 8463   # 443 + 20
            admin = 8281   # 81 + 20*10
        }
        domains = @{
            openemr = "dev.localhost"
            telehealth = "vc-dev.localhost"
            jitsi = "vcbknd-dev.localhost"
        }
    }
    test = @{
        dirName = "$Project-test"
        projectName = "$Project-test"
        portOffset = 30
        npmPorts = @{
            http = 8083    # 80 + 30*1
            https = 8473   # 443 + 30
            admin = 8381   # 81 + 30*10
        }
        domains = @{
            openemr = "test.localhost"
            telehealth = "vc-test.localhost"
            jitsi = "vcbknd-test.localhost"
        }
    }
}

# For backward compatibility
if ($StagingEnvironment) {
    $Environment = "staging"
}

# Get environment configuration
if (-not [string]::IsNullOrEmpty($Environment)) {
    $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase
    
    # Define the environment directory
    $environmentDir = "$workingDirectory\$($envConfig.DirectoryName)"
    
    # Check if the environment directory exists
    if (-not (Test-Path $environmentDir)) {
        Write-Host "Environment directory not found: $environmentDir" -ForegroundColor Red
        Write-Host "Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
        exit 1
    }
    
    # Define component directories
    $openemrDir = "$environmentDir\$OpenEmrFolder"
    $telehealthDir = "$environmentDir\$TelehealthFolder"
    $jitsiDir = "$environmentDir\$JitsiFolder"
    $proxyDir = "$environmentDir\$ProxyFolder"
    
    # Set base project name from environment config
    $baseProjectName = $envConfig.ProjectName
} else {
    # Default to using source repositories if no environment is specified
    $openemrDir = "$SourceReposDir\openemr-telesalud"
    $telehealthDir = "$SourceReposDir\ciips-telesalud"
    $jitsiDir = "$SourceReposDir\ciips-telesalud\jitsi-docker"
    $proxyDir = "$workingDirectory\$ProxyFolder"
    
    # Default project name
    $baseProjectName = "aiotp"
}

# Source repository variables
$openemrSourceDir = "$SourceReposDir\openemr-telesalud"
$telehealthSourceDir = "$SourceReposDir\ciips-telesalud"

# Check if source repositories exist
if (Test-Path $openemrSourceDir) {
    Write-Host "Found OpenEMR source repository at: $openemrSourceDir" -ForegroundColor Green
} else {
    Write-Host "OpenEMR source repository not found at: $openemrSourceDir" -ForegroundColor Yellow
    Write-Host "Some features may not work correctly. Run backup-and-staging.ps1 with -UpdateSourceRepos switch first." -ForegroundColor Yellow
}

if (Test-Path $telehealthSourceDir) {
    Write-Host "Found Telehealth source repository at: $telehealthSourceDir" -ForegroundColor Green
} else {
    Write-Host "Telehealth source repository not found at: $telehealthSourceDir" -ForegroundColor Yellow
    Write-Host "Some features may not work correctly. Run backup-and-staging.ps1 with -UpdateSourceRepos switch first." -ForegroundColor Yellow
}

# Display environment information
Write-Host "All-In-One Telehealth Platform Setup" -ForegroundColor Cyan

# Function to get container by pattern
function Get-Container {
    param (
        [string]$ComponentPattern,
        [string]$Suffix = ""
    )
    
    # Build a pattern that will match containers for this project and environment
    $containerPattern = "^$baseProjectName-$ComponentPattern$Suffix$"
    Write-Host "Looking for container with pattern: $containerPattern" -ForegroundColor Yellow
    
    # Try to find containers matching the pattern
    $container = docker ps --format "{{.Names}}" | Where-Object { $_ -match $containerPattern } | Select-Object -First 1
    
    if ($container) {
        Write-Host "Found container: $container" -ForegroundColor Green
    } else {
        Write-Host "No container found matching pattern: $containerPattern" -ForegroundColor Yellow
    }
    
    return $container
}

Write-Host "===================================" -ForegroundColor Cyan
Write-Host "Environment: $(if ($Environment) { (Get-Culture).TextInfo.ToTitleCase($Environment) } else { 'Production' })" -ForegroundColor Cyan
Write-Host "Project Name: $baseProjectName" -ForegroundColor Cyan
Write-Host "Domain Base: $DomainBase" -ForegroundColor Cyan
Write-Host "Frontend Network: $env:FRONTEND_NETWORK" -ForegroundColor Cyan
Write-Host "Proxy Network: $env:PROXY_NETWORK" -ForegroundColor Cyan
Write-Host "HTTP Port: $env:HTTP_PORT" -ForegroundColor Cyan
Write-Host "HTTPS Port: $env:HTTPS_PORT" -ForegroundColor Cyan
Write-Host "Admin Port: $env:ADMIN_PORT" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan

# Function to handle errors and provide guidance
function Handle-Error {
    param (
        [string]$ErrorMessage,
        [string]$SuggestedAction = "",
        [bool]$Fatal = $false
    )
    
    Write-Host ""
    Write-Host "ERROR: $ErrorMessage" -ForegroundColor Red
    
    if ($SuggestedAction -ne "") {
        Write-Host "SUGGESTION: $SuggestedAction" -ForegroundColor Yellow
    }
    
    if ($Fatal) {
        Write-Host "This is a fatal error. Script execution will stop." -ForegroundColor Red
        exit 1
    } else {
        $continue = Get-UserInput "Do you want to continue anyway? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
        if ($continue -eq "n") {
            Write-Host "Script execution stopped by user." -ForegroundColor Yellow
            exit 0
        }
    }
    
    Write-Host ""
}

# Function to check if Docker is running
function Test-DockerRunning {
    try {
        $dockerInfo = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

# Function to invoke docker-compose with proper error handling
function Invoke-DockerCompose {
    param (
        [string]$Command,
        [string]$WorkingDirectory
    )
    
    try {
        $currentLocation = Get-Location
        Set-Location -Path $WorkingDirectory
        
        # Check if .env file exists in the current directory
        if (Test-Path -Path ".env") {
            Write-Host "Found .env file in current directory, using it for Docker Compose" -ForegroundColor Cyan
            Write-Host "Running: docker-compose $Command" -ForegroundColor Cyan
            Invoke-Expression "docker-compose $Command"
        } else {
            Write-Host "Warning: No .env file found in $WorkingDirectory" -ForegroundColor Yellow
            Write-Host "Running: docker-compose $Command" -ForegroundColor Cyan
            Invoke-Expression "docker-compose $Command"
        }
        
        Set-Location -Path $currentLocation
        return $true
    }
    catch {
        Write-Host "Error executing docker-compose command: $_" -ForegroundColor Red
        Set-Location -Path $currentLocation
        return $false
    }
}

# Function to check MySQL readiness
function Test-MySQLReady {
    param(
        [string]$ContainerName
    )
    
    Write-Host "Checking if MySQL is ready in container $ContainerName..." -ForegroundColor Yellow
    $maxAttempts = 12
    $attempt = 1
    
    while ($attempt -le $maxAttempts) {
        $result = docker exec $ContainerName mysqladmin ping 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "MySQL is ready!" -ForegroundColor Green
            return $true
        }
        Write-Host "Waiting for MySQL to be ready (attempt $attempt of $maxAttempts)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        $attempt++
    }
    
    Write-Host "MySQL did not become ready within the timeout period." -ForegroundColor Red
    return $false
}

# Display setup information
Write-Host "Remove Volumes: $RemoveVolumes" -ForegroundColor Cyan
Write-Host "Skip Certificate Generation: $SkipCertificateGeneration" -ForegroundColor Cyan
Write-Host "Skip NPM Configuration: $SkipNpmConfiguration" -ForegroundColor Cyan
Write-Host "Skip Hosts Check: $SkipHostsCheck" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan

# Create Docker networks first
Write-Host "Step 1: Creating Docker Networks" -ForegroundColor Cyan
Write-Host "---------------------------------" -ForegroundColor Cyan

# Create frontend network
Write-Host "Creating frontend network ($env:FRONTEND_NETWORK)..." -ForegroundColor Green
docker network create $env:FRONTEND_NETWORK 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Frontend network $env:FRONTEND_NETWORK already exists" -ForegroundColor Yellow
}

# Create proxy network
Write-Host "Creating proxy network ($env:PROXY_NETWORK)..." -ForegroundColor Green
docker network create $env:PROXY_NETWORK 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Proxy network $env:PROXY_NETWORK already exists" -ForegroundColor Yellow
}

# Create generic networks for docker-compose files that use hardcoded network names
Write-Host "Creating generic frontend network..." -ForegroundColor Green
docker network create frontend 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Generic frontend network already exists" -ForegroundColor Yellow
}

Write-Host "Creating generic proxy_default network..." -ForegroundColor Green
docker network create proxy_default 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Generic proxy_default network already exists" -ForegroundColor Yellow
}


# Display network information
Write-Host "Networks created successfully:" -ForegroundColor Green
Write-Host "- Environment Frontend Network: $env:FRONTEND_NETWORK" -ForegroundColor Green
Write-Host "- Environment Proxy Network: $env:PROXY_NETWORK" -ForegroundColor Green
Write-Host "- Generic Frontend Network: frontend" -ForegroundColor Green
Write-Host "- Generic Proxy Network: proxy_default" -ForegroundColor Green
Write-Host "---------------------------------" -ForegroundColor Cyan

# Now proceed with service setup
Write-Host "Step 2: Service Setup" -ForegroundColor Cyan
Write-Host "---------------------------------" -ForegroundColor Cyan

# Keep the initial cleanup questions and functions at the top
$stopContainers = Get-UserInput "Do you want to stop all running containers? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
$pruneNetworks = Get-UserInput "Do you want to prune unused Docker networks? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
$pruneVolumes = Get-UserInput "Do you want to prune unused Docker volumes? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

# Execute cleanup based on user responses
if ($stopContainers -eq "y") {
    Write-Host "Stopping project components..." -ForegroundColor Yellow
    foreach ($component in $components) {
        Stop-ProjectComponent -Name $component.Name -ProjectName $component.ProjectName -Environment $Environment
    }
}

if ($pruneNetworks -eq "y") {
    Remove-ProjectNetworks -ProjectName $baseProjectName -Environment $Environment
    docker network prune -f
}

# Use RemoveVolumes parameter to control volume removal without additional prompts
if ($RemoveVolumes) {
    Write-Host "RemoveVolumes parameter is set. Volumes will be removed during cleanup." -ForegroundColor Yellow
}

# Main script execution
Write-Host "All-In-One Telehealth Platform Setup" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan

# Check if Docker is running
if (-not (Test-DockerRunning)) {
    Handle-Error -ErrorMessage "Docker is not running or not installed." -SuggestedAction "Please start Docker Desktop or install Docker if not already installed." -Fatal $true
}

# Variable to track if volumes have already been handled by shutdown script
$volumesHandledByShutdown = $false

# Display a message about the docker-compose.yml files being updated
Write-Host ""
Write-Host "All-In-One Telehealth Platform Setup" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Docker Compose files have been updated to remove obsolete 'version' attribute." -ForegroundColor Green
Write-Host "This will eliminate warnings in the logs." -ForegroundColor Green
Write-Host ""

# Option to prune all images
$pruneImages = Get-UserInput "Do you want to prune all Docker images? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "n"
if ($pruneImages -eq "y") {
    Write-Host "Pruning all Docker images..." -ForegroundColor Yellow
    docker image prune -a -f
    Write-Host "All unused Docker images have been removed." -ForegroundColor Green
}

# Handle database volumes if they haven't been handled by shutdown script
if (-not $volumesHandledByShutdown) {
    Handle-AllVolumes -ProjectName $baseProjectName
}

# Create frontend network
Write-Host "Creating frontend network ($env:FRONTEND_NETWORK)..." -ForegroundColor Green
docker network create $env:FRONTEND_NETWORK 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Frontend network $env:FRONTEND_NETWORK already exists" -ForegroundColor Yellow
}

# Create proxy network
Write-Host "Creating proxy network ($env:PROXY_NETWORK)..." -ForegroundColor Green
docker network create $env:PROXY_NETWORK 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Proxy network $env:PROXY_NETWORK already exists" -ForegroundColor Yellow
}

# Create generic networks for docker-compose files that use hardcoded network names
Write-Host "Creating generic frontend network..." -ForegroundColor Green
docker network create frontend 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Generic frontend network already exists" -ForegroundColor Yellow
}

Write-Host "Creating generic proxy_default network..." -ForegroundColor Green
docker network create proxy_default 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Generic proxy_default network already exists" -ForegroundColor Yellow
}

# Setup Proxy
Write-Host "Step 7: Proxy Setup" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "Setting up Nginx Proxy Manager..." -ForegroundColor Green

# Define the Proxy path
$proxyPath = $proxyDir

if (-not (Test-Path -Path $proxyPath)) {
    Write-Host "Proxy directory not found at $proxyPath" -ForegroundColor Red
    Write-Host "Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
    return
} else {
    Write-Host "Using Proxy directory at: $proxyPath" -ForegroundColor Green
}

# Save current location
$currentLocation = Get-Location

# Change to Proxy directory
Set-Location -Path $proxyPath

# Check if proxy containers are already running
$existingProxyContainers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^$baseProjectName-$ProxyFolder" }
if ($existingProxyContainers) {
    Write-Host "Proxy containers are already running. Skipping docker-compose up." -ForegroundColor Yellow
    } else {
    # Start Nginx Proxy Manager
    Write-Host "Starting Nginx Proxy Manager..." -ForegroundColor Green
    $composeResult = Invoke-DockerCompose -Command "up -d" -WorkingDirectory (Get-Location).Path
    
    if (-not $composeResult) {
        Write-Host "Failed to start Nginx Proxy Manager. Check the logs for more information." -ForegroundColor Red
        return
    }
    
    # Wait for Nginx Proxy Manager to be ready
    Write-Host "Waiting for Nginx Proxy Manager to be ready..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

# Fix network connections for Proxy containers
Write-Host "Fixing network connections for Proxy containers..." -ForegroundColor Yellow
if ($Environment) {
    & "$PSScriptRoot\fix-network-connections.ps1" -Environment $Environment -Component "proxy" -SourceReposDir $SourceReposDir -Project $Project
} else {
    & "$PSScriptRoot\fix-network-connections.ps1" -Component "proxy" -SourceReposDir $SourceReposDir -Project $Project
}

# Return to previous location
Set-Location -Path $currentLocation


# Generate SSL certificates
Write-Host "Step 8: SSL Certificate Generation" -ForegroundColor Cyan
Write-Host "--------------------------" -ForegroundColor Cyan

if (Test-ScriptExists -ScriptName "generate-certs.ps1") {
    $generateCerts = Get-UserInput "Do you want to generate SSL certificates? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

    if ($generateCerts -eq "y") {
        Write-Host "Generating SSL certificates..." -ForegroundColor Green
        
        try {
            $generateCertsScript = Join-Path $PSScriptRoot "generate-certs.ps1"
            
            # Build the command with proper parameter handling
            $cmd = "& '$generateCertsScript'"
            if ($Environment) {
                $cmd += " -Environment $Environment"
            }
            $cmd += " -Project $Project -SourceReposDir `"$SourceReposDir`""
            if ($DomainBase) {
                $cmd += " -DomainBase $DomainBase"
            }
            $cmd += " -Force"
            
            Write-Host "Running: $cmd" -ForegroundColor Yellow
            
            # Execute the command
            Invoke-Expression $cmd
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Failed to generate SSL certificates." -ForegroundColor Red
                Write-Host "Please check the error messages above and try again." -ForegroundColor Yellow
            } else {
                Write-Host "SSL certificates have been generated successfully." -ForegroundColor Green
            }
        } catch {
            Write-Host "Error generating SSL certificates: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Skipping SSL certificate generation." -ForegroundColor Yellow
    }
} else {
    Write-Host "generate-certs.ps1 script not found. Skipping certificate generation." -ForegroundColor Red
    Write-Host "Please make sure the script exists in the current directory." -ForegroundColor Yellow
}


# Setup Telehealth containers
Write-Host "Step 5: Telehealth Setup" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "Setting up Telehealth..." -ForegroundColor Green

# Define the telehealth path
$telehealthPath = $telehealthDir

if (-not (Test-Path -Path $telehealthPath)) {
    Write-Host "Telehealth directory not found at $telehealthPath" -ForegroundColor Red
    Write-Host "Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
    return
} else {
    Write-Host "Using Telehealth directory at: $telehealthPath" -ForegroundColor Green
    
    # Save current location
    $currentLocation = Get-Location
    
    # Change to the Telehealth directory
    Set-Location -Path "$telehealthPath"
    
    # Check if docker-compose.yml file exists
    if (-not (Test-Path -Path "docker-compose.yml")) {
        Write-Host "Error: docker-compose.yml not found. Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
        return
    } else {
        Write-Host "Using existing docker-compose.yml for Telehealth" -ForegroundColor Green
    }
    
    # Prepare certificates for telehealth container
    Write-Host "Preparing SSL certificates for Telehealth..." -ForegroundColor Green
    
    # Create docker-config directory in the telehealth folder if it doesn't exist
    $dockerConfigPath = Join-Path -Path $telehealthPath -ChildPath "docker-config"
    if (-not (Test-Path -Path $dockerConfigPath)) {
        New-Item -Path $dockerConfigPath -ItemType Directory -Force | Out-Null
        Write-Host "Created docker-config directory for telehealth" -ForegroundColor Green
    }
    
    # Check if we have certificates in the docker-config directory
    if ((Test-Path "$dockerConfigPath/cert.key") -and (Test-Path "$dockerConfigPath/cert.crt")) {
        Write-Host "SSL certificates found in docker-config directory." -ForegroundColor Green
        
    } else {
        Write-Host "SSL certificates not found in docker-config directory." -ForegroundColor Yellow
    }   
    # Still start containers even if certificates are not present
    $existingContainers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^$baseProjectName-telehealth" }
        
    if ($existingContainers) {
        Write-Host "Telehealth containers are already running. Restarting them to apply changes..." -ForegroundColor Yellow
        Invoke-DockerCompose -Command "restart" -WorkingDirectory (Get-Location).Path
    } else {
        # Start containers
        Write-Host "Starting Telehealth containers with docker-compose..." -ForegroundColor Green
        Invoke-DockerCompose -Command "up -d" -WorkingDirectory (Get-Location).Path
    }

    
    # Return to the original directory
    Set-Location -Path $currentLocation
}

# Note: SSL termination is now handled exclusively by Nginx Proxy Manager
Write-Host "SSL termination is now handled exclusively by Nginx Proxy Manager." -ForegroundColor Green
Write-Host "Certificates are only required in the Telehealth container for internal use." -ForegroundColor Green

# Ask if the user wants to run first-time setup commands for the telehealth application
$runSetupTelehealth = Get-UserInput "Do you want to run first-time setup commands for the telehealth application? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

if ($runSetupTelehealth -eq "y") {
    Test-MySQLReady -ContainerName "$baseProjectName-$telehealthFolder-database-1"
    # First, install required dependencies for Composer using root user
    Write-Host "Installing required PHP dependencies..." -ForegroundColor Green
    docker exec -it -u 0 $baseProjectName-$telehealthFolder-app-1 apt-get update
    docker exec -it -u 0 $baseProjectName-$telehealthFolder-app-1 apt-get install -y zip unzip libzip-dev
    docker exec -it -u 0 $baseProjectName-$telehealthFolder-app-1 docker-php-ext-install zip
    
    Write-Host "Running composer install..." -ForegroundColor Green
    docker exec -it $baseProjectName-$telehealthFolder-app-1 composer install --working-dir=/var/www
    
    Write-Host "Generating application key..." -ForegroundColor Green
    docker exec -it $baseProjectName-$telehealthFolder-app-1 php /var/www/artisan key:generate --force
    
    Write-Host "Running database migrations..." -ForegroundColor Green
    docker exec -it $baseProjectName-$telehealthFolder-app-1 bash -c "echo 'yes' | php /var/www/artisan migrate --force"
    
    Write-Host "Running database seeding..." -ForegroundColor Green
    docker exec -it $baseProjectName-$telehealthFolder-app-1 bash -c "echo 'yes' | php /var/www/artisan db:seed --force"
    
    Write-Host "Generating API token..." -ForegroundColor Green
    $rawToken = docker exec -it $baseProjectName-$telehealthFolder-app-1 bash -c "echo 'yes' | php /var/www/artisan token:issue"
    # Extract just the token part (everything after the last space)
    $token = $rawToken -split " " | Select-Object -Last 1
    # Remove any ANSI color codes and extra characters
    $token = $token -replace '\x1B\[[0-9;]*[mK]', '' -replace '\[39m', ''
    Write-Host "API Token: $token" -ForegroundColor Yellow

    # Update OpenEMR's .env with the token
    # Determine the correct path based on project type
    $openemrEnvPath = if ($Project -eq "official") {
        # Path for official project
        "$PSScriptRoot\$($envConfig.DirectoryName)\openemr\.env"
    } else {
        # Path for non-official projects
        "$openemrDir\.env"
    }
    
    Write-Host "Updating OpenEMR .env at: $openemrEnvPath" -ForegroundColor Yellow
    
    if (Test-Path $openemrEnvPath) {
        try {
            $envContent = Get-Content $openemrEnvPath -Raw
            $envContent = $envContent -replace "TELEHEALTH_API_TOKEN=.*", "TELEHEALTH_API_TOKEN=$token"
            Set-Content -Path $openemrEnvPath -Value $envContent
            Write-Host "Successfully updated OpenEMR .env with new API token" -ForegroundColor Green
        } catch {
            Write-Host "Error updating OpenEMR .env: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "OpenEMR .env file not found at: $openemrEnvPath" -ForegroundColor Red
    }

    # Update environment config with the token
    try {
        $envConfig.Config.containerPorts.telehealth.api_token = $token
        Write-Host "Successfully stored API token in environment configuration" -ForegroundColor Green
    } catch {
        Write-Host "Error storing API token in environment configuration: $_" -ForegroundColor Red
    }

    # Return to the original directory
} else {
    Write-Host "Telehealth Database Setup not completed." -ForegroundColor Cyan
}

# Fix network connections to ensure all containers are properly connected
Write-Host "Fixing network connections for OpenEMR containers..." -ForegroundColor Yellow
if ($Environment) {
    & "$PSScriptRoot\fix-network-connections.ps1" -Environment $Environment -Component "telehealth" -SourceReposDir $SourceReposDir -Project $Project
} else {
    & "$PSScriptRoot\fix-network-connections.ps1" -Component "telehealth" -SourceReposDir $SourceReposDir -Project $Project
}

# Setup OpenEMR
Write-Host "Step 4: OpenEMR Setup" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "Setting up OpenEMR..." -ForegroundColor Green

# Define the appropriate OpenEMR directory path based on project type
if ($Project -eq "official") {
    # For official project
    $targetDir = Join-Path -Path $PSScriptRoot -ChildPath $envConfig.DirectoryName
    $openemrPath = Join-Path -Path $targetDir -ChildPath $envConfig.FolderNames.openemr

    # Create target directories if they don't exist
    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        Write-Host "Created target directory: $targetDir" -ForegroundColor Green
    }

    if (-not (Test-Path -Path $openemrPath)) {
        New-Item -Path $openemrPath -ItemType Directory -Force | Out-Null
        Write-Host "Created OpenEMR target directory: $openemrPath" -ForegroundColor Green
    }

    # Get the OpenEMR source directory
    $openemrSourceDir = "$SourceReposDir\openemr"
    if (-not (Test-Path -Path $openemrSourceDir)) {
        Write-Host "OpenEMR source repository not found at $openemrSourceDir" -ForegroundColor Red
        Write-Host "Please run update-source-repos.ps1 first to clone the repositories." -ForegroundColor Red
        return
    }

    # Determine which docker-compose.yml to use based on environment and ARM flag
    $dockerComposeSourcePath = ""
    if ($Environment -eq "production" -or $Environment -eq "") {
        if ($ARM) {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\production-arm\docker-compose.yml"
            Write-Host "Using production ARM docker-compose.yml" -ForegroundColor Cyan
        } else {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\production\docker-compose.yml"
            Write-Host "Using production docker-compose.yml" -ForegroundColor Cyan
        }
    } elseif ($Environment -eq "dev") {
        if ($ARM) {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\development-easy-arm\docker-compose.yml"
            Write-Host "Using development-easy ARM docker-compose.yml" -ForegroundColor Cyan
        } else {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\development-easy\docker-compose.yml"
            Write-Host "Using development-easy docker-compose.yml" -ForegroundColor Cyan
        }
    } else {
        # Default to production for other environments
        if ($ARM) {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\production-arm\docker-compose.yml"
            Write-Host "Using production ARM docker-compose.yml for $Environment environment" -ForegroundColor Cyan
        } else {
            $dockerComposeSourcePath = Join-Path -Path $openemrSourceDir -ChildPath "docker\production\docker-compose.yml"
            Write-Host "Using production docker-compose.yml for $Environment environment" -ForegroundColor Cyan
        }
    }

    $targetDockerCompose = Join-Path -Path $openemrPath -ChildPath "docker-compose.yml"

    # Check if the selected docker-compose file exists
    if (-not (Test-Path -Path $dockerComposeSourcePath)) {
        Write-Host "Error: Docker Compose file not found at $dockerComposeSourcePath" -ForegroundColor Red
        
        # Suggest alternative paths that might exist
        $possiblePaths = @(
            "docker\production\docker-compose.yml",
            "docker\production-arm\docker-compose.yml",
            "docker\development-easy\docker-compose.yml",
            "docker\development-easy-arm\docker-compose.yml"
        )
        
        Write-Host "Checking for alternative docker-compose files..." -ForegroundColor Yellow
        foreach ($path in $possiblePaths) {
            $fullPath = Join-Path -Path $openemrSourceDir -ChildPath $path
            if (Test-Path -Path $fullPath) {
                Write-Host "Found alternative docker-compose file at: $path" -ForegroundColor Green
                $dockerComposeSourcePath = $fullPath
                break
            }
        }
        
        if (-not (Test-Path -Path $dockerComposeSourcePath)) {
            Write-Host "No alternative docker-compose files found. Please check your OpenEMR repository." -ForegroundColor Red
            return
        }
    }

    if (-not (Test-Path -Path $targetDockerCompose) -or $Force) {
        Write-Host "Copying and adapting Docker Compose file from $dockerComposeSourcePath..." -ForegroundColor Yellow
        $dockerComposeContent = Get-Content -Path $dockerComposeSourcePath -Raw

        # Replace the ports with environment-specific values
        $httpPort = $envConfig.Config.containerPorts.openemr.http
        $httpsPort = $envConfig.Config.containerPorts.openemr.https

        Write-Host "Replacing port mappings: 80 -> $httpPort, 443 -> $httpsPort" -ForegroundColor Yellow
        
        # Instead of complex regex, use a more reliable line-by-line approach
        $lines = $dockerComposeContent -split "`n"
        $inPorts = $false
        $updatedLines = @()
        
        foreach ($line in $lines) {
            # Check if we're entering the ports section
            if ($line -match '^\s+ports:\s*$') {
                $inPorts = $true
                $updatedLines += $line
                continue
            }
            
            # If we're in the ports section, handle port replacements
            if ($inPorts) {
                if ($line -match '^\s+-\s+(\")?(80:80)(\")?\s*$') {
                    # This is the HTTP port line - preserve quote style
                    $hasQuotes = $matches[1] -ne $null -and $matches[1] -ne ""
                    if ($hasQuotes) {
                        $updatedLines += $line -replace '"80:80"', """$httpPort`:80"""
                    } else {
                        $updatedLines += $line -replace '80:80', "$httpPort`:80"
                    }
                    continue
                }
                elseif ($line -match '^\s+-\s+(\")?(443:443)(\")?\s*$') {
                    # This is the HTTPS port line - preserve quote style
                    $hasQuotes = $matches[1] -ne $null -and $matches[1] -ne ""
                    if ($hasQuotes) {
                        $updatedLines += $line -replace '"443:443"', """$httpsPort`:443"""
                    } else {
                        $updatedLines += $line -replace '443:443', "$httpsPort`:443"
                    }
                    continue
                }
                elseif ($line -match '^\s+-') {
                    # Still in ports section but with a different port
                    $updatedLines += $line
                    continue
                }
                else {
                    # No longer in ports section
                    $inPorts = $false
                }
            }
            
            # Add the unchanged line
            $updatedLines += $line
        }
        
        # Join the lines back together
        $dockerComposeContent = $updatedLines -join "`n"

        # Add project name to prevent conflicts
        $dockerComposeContent = "# Docker Compose for Official OpenEMR - $Environment`n`nversion: '3.1'`nname: $($envConfig.ProjectName)`n" + ($dockerComposeContent -replace "version: '3.1'", "")

        # Add Telehealth environment variables to the openemr service
        $lines = $dockerComposeContent -split "`n"
        $openemrServiceIndex = -1
        $environmentIndex = -1
        
        # Find the openemr service and its environment section
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s+openemr:") {
                $openemrServiceIndex = $i
            }
            if ($openemrServiceIndex -ne -1 -and $lines[$i] -match "^\s+environment:") {
                $environmentIndex = $i
                break
            }
        }
        
        # If we found the environment section, add our variables after the last environment variable
        if ($environmentIndex -ne -1) {
            $lastEnvVarIndex = $environmentIndex
            $indentation = ""
            
            # Find the last environment variable and its indentation
            for ($i = $environmentIndex + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^(\s+)\S+:" -and $lines[$i-1] -match "^\s+\S+: \S+") {
                    # This line has different indentation, so we've moved past the environment section
                    break
                }
                if ($lines[$i] -match "^(\s+)(\S+): \S+") {
                    $lastEnvVarIndex = $i
                    $indentation = $matches[1]
                }
            }
            
            # Add our Telehealth variables after the last environment variable with the same indentation
            $teleHealthVars = @(
                "$($indentation)TELEHEALTH_EXTERNAL_URL: `${TELEHEALTH_EXTERNAL_URL}",
                "$($indentation)TELEHEALTH_EXTERNAL_HTTPS_URL: `${TELEHEALTH_EXTERNAL_HTTPS_URL}",
                "$($indentation)TELEHEALTH_API_TOKEN: `${TELEHEALTH_API_TOKEN}",
                "$($indentation)NOTIFICATION_TOKEN: `${NOTIFICATION_TOKEN}",
                "$($indentation)TELEHEALTH_BASE_URL: `${TELEHEALTH_BASE_URL}",
                "$($indentation)VC_API: `${VC_API}",
                "$($indentation)VC_API_DATA: `${VC_API_DATA}",
                "$($indentation)TELEHEALTH_PORT: `${TELEHEALTH_PORT}",
                "$($indentation)VC_API_URL: `${VC_API_URL}",
                "$($indentation)VC_API_TOKEN: `${VC_API_TOKEN}",
                "$($indentation)VC_API_PORT: `${VC_API_PORT}",
                "$($indentation)OPS_DB_HOST: `${OPS_DB_HOST}",
                "$($indentation)OPS_DB_USER: `${OPS_DB_USER}",
                "$($indentation)OPS_DB_PASSWORD: `${OPS_DB_PASSWORD}",
                "$($indentation)OPS_DB_DATABASE: `${OPS_DB_DATABASE}",
                "$($indentation)OPS_NOTIFICATIONS_ENDPOINT: `${OPS_NOTIFICATIONS_ENDPOINT}"
            ) 
            
            $lines = $lines[0..$lastEnvVarIndex] + $teleHealthVars + $lines[($lastEnvVarIndex+1)..($lines.Count-1)]
            $dockerComposeContent = $lines -join "`n"
        }
        
        # Add network configuration
        $networksConfig = @"

networks:
  default:
    external:
      name: $($envConfig.FrontendNetwork)
"@

        $dockerComposeContent += $networksConfig

        # Save the modified Docker Compose file
        Set-Content -Path $targetDockerCompose -Value $dockerComposeContent -Force
        Write-Host "Created customized Docker Compose file at $targetDockerCompose" -ForegroundColor Green

        # Create .env file
        # Look for .env.example in the source repository
        $sourceReposDir = "$PSScriptRoot\source-repos"
        $envExamplePath = "$sourceReposDir\openemr\.env.example"
        $envFilePath = Join-Path -Path $openemrPath -ChildPath ".env"
        
        Write-Host "Looking for OpenEMR .env.example file at: $envExamplePath" -ForegroundColor Yellow
        
        if (Test-Path $envExamplePath) {
            # Use .env.example as a template
            Write-Host "Found OpenEMR .env.example file, using it as a template" -ForegroundColor Green
            try {
                # Read the .env.example file content
                $envContent = Get-Content -Path $envExamplePath -Raw
                
                # Add timestamp and environment information
                $timestamp = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
                $envContent = "# Environment file for Official OpenEMR - $Environment`r`n# Generated: $timestamp`r`n$envContent"
                
                # Ensure all required variables are set
                $envContent = $envContent -replace "COMPOSE_PROJECT_NAME=.*", "COMPOSE_PROJECT_NAME=$($envConfig.ProjectName)"
                
                # Set HTTP and HTTPS ports
                if (-not ($envContent -match "HTTP_PORT=")) {
                    $envContent += "`nHTTP_PORT=$httpPort"
                } else {
                    $envContent = $envContent -replace "HTTP_PORT=.*", "HTTP_PORT=$httpPort"
                }
                
                if (-not ($envContent -match "HTTPS_PORT=")) {
                    $envContent += "`nHTTPS_PORT=$httpsPort"
                } else {
                    $envContent = $envContent -replace "HTTPS_PORT=.*", "HTTPS_PORT=$httpsPort"
                }
                
                # Add domain setting if not present
                if (-not ($envContent -match "DOMAIN=")) {
                    $envContent += "`r`nDOMAIN=$($envConfig.Domains.openemr)"
                } else {
                    $envContent = $envContent -replace "DOMAIN=.*", "DOMAIN=$($envConfig.Domains.openemr)"
                }
                
                # Add telehealth API settings
                $prefix = if ($Environment -eq "production") { "" } else { "$Environment-" }
                
                # Add Telehealth API settings
                if (-not ($envContent -match "TELEHEALTH_BASE_URL=")) {
                    $envContent += "`r`nTELEHEALTH_BASE_URL=https://$($envConfig.Domains.telehealth)"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_BASE_URL=.*", "TELEHEALTH_BASE_URL=https://$($envConfig.Domains.telehealth)"
                }
                
                # Add Telehealth API settings
                if (-not ($envContent -match "TELEHEALTH_PORT=")) {
                    $envContent += "`r`nTELEHEALTH_PORT=443"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_PORT=.*", "TELEHEALTH_PORT=443"
                }
                
                #if (-not ($envContent -match "TELEHEALTH_BASE_URL=")) {
                #    $envContent += "`r`nTELEHEALTH_BASE_URL=http://$Project-$Environment-telehealth-web-1:\${TELEHEALTH_PORT}"
                #} else {
                #    $envContent = $envContent -replace "TELEHEALTH_BASE_URL=.*", "TELEHEALTH_BASE_URL=http://$Project-$Environment-telehealth-web-1:\${TELEHEALTH_PORT}"
                #}

                if (-not ($envContent -match "VC_API_URL=")) {
                    $envContent += "`r`nVC_API_URL=https://$($envConfig.Domains.telehealth)"
                } else {
                    $envContent = $envContent -replace "VC_API_URL=.*", "VC_API_URL=https://$($envConfig.Domains.telehealth)"
                }

                #if (-not ($envContent -match "VC_API_URL=")) {
                #    $envContent += "`r`nVC_API_URL=http://$Project-$Environment-telehealth-web-1:\${VC_API_PORT}"
                #} else {
                #    $envContent = $envContent -replace "VC_API_URL=.*", "VC_API_URL=http://$Project-$Environment-telehealth-web-1:\${VC_API_PORT}"
                #}
                
                if (-not ($envContent -match "VC_API=")) {
                    $envContent += "`r`nVC_API=/api/videoconsultation?"
                } else {
                    $envContent = $envContent -replace "VC_API=.*", "VC_API=/api/videoconsultation?"
                }
                
                if (-not ($envContent -match "VC_API_DATA=")) {
                    $envContent += "`r`nVC_API_DATA=/api/videoconsultation/data?"
                } else {
                    $envContent = $envContent -replace "VC_API_DATA=.*", "VC_API_DATA=/api/videoconsultation/data?"
                }
                
                if (-not ($envContent -match "TELEHEALTH_PORT=")) {
                    $envContent += "`r`nTELEHEALTH_PORT=443"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_PORT=.*", "TELEHEALTH_PORT=443"
                }
                if (-not ($envContent -match "VC_API_PORT=")) {
                    $envContent += "`r`nVC_API_PORT=443"
                } else {
                    $envContent = $envContent -replace "VC_API_PORT=.*", "VC_API_PORT=443"
                }
                if (-not ($envContent -match "TELEHEALTH_API_TOKEN=")) {
                    $envContent += "`r`nTELEHEALTH_API_TOKEN=$($envConfig.Config.containerPorts.telehealth.api_token)"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_API_TOKEN=.*", "TELEHEALTH_API_TOKEN=$($envConfig.Config.containerPorts.telehealth.api_token)"
                }
                if (-not ($envContent -match "VC_API_TOKEN=")) {
                    $envContent += "`r`nVC_API_TOKEN=$($envConfig.Config.containerPorts.telehealth.api_token)"
                } else {
                    $envContent = $envContent -replace "VC_API_TOKEN=.*", "VC_API_TOKEN=$($envConfig.Config.containerPorts.telehealth.api_token)"
                }
                
                # Add database connection settings
                if (-not ($envContent -match "OPS_DB_HOST=")) {
                    $envContent += "`r`nOPS_DB_HOST=localhost"
                } else {
                    $envContent = $envContent -replace "OPS_DB_HOST=.*", "OPS_DB_HOST=localhost"
                }
                
                if (-not ($envContent -match "OPS_DB_USER=")) {
                    $envContent += "`r`nOPS_DB_USER=openemr"
                } else {
                    $envContent = $envContent -replace "OPS_DB_USER=.*", "OPS_DB_USER=openemr"
                }
                
                if (-not ($envContent -match "OPS_DB_PASSWORD=")) {
                    $envContent += "`r`nOPS_DB_PASSWORD=openemr"
                } else {
                    $envContent = $envContent -replace "OPS_DB_PASSWORD=.*", "OPS_DB_PASSWORD=openemr"
                }
                
                if (-not ($envContent -match "OPS_DB_DATABASE=")) {
                    $envContent += "`r`nOPS_DB_DATABASE=openemr"
                } else {
                    $envContent = $envContent -replace "OPS_DB_DATABASE=.*", "OPS_DB_DATABASE=openemr"
                }
                
                if (-not ($envContent -match "OPS_NOTIFICATIONS_ENDPOINT=")) {
                    $envContent += "`r`nOPS_NOTIFICATIONS_ENDPOINT="
                } else {
                    $envContent = $envContent -replace "OPS_NOTIFICATIONS_ENDPOINT=.*", "OPS_NOTIFICATIONS_ENDPOINT=http://$Project-$Environment-openemr-1:$($envConfig.Config.containerPorts.npm.http)/interface/modules/custom_modules/oe-telehealth-module/api/notifications_simple.php"
                }
                
                if (-not ($envContent -match "NOTIFICATION_TOKEN=")) {
                    $envContent += "`r`nNOTIFICATION_TOKEN=openemr-telehealth-secret-2024"
                } else {
                    $envContent = $envContent -replace "NOTIFICATION_TOKEN=.*", "NOTIFICATION_TOKEN=openemr-telehealth-secret-2024"
                }
                
                # Add Telehealth external URL if not present
                if (-not ($envContent -match "TELEHEALTH_EXTERNAL_URL=")) {
                    $envContent += "`r`nTELEHEALTH_EXTERNAL_URL=http://$($envConfig.Domains.telehealth):$($envConfig.Config.containerPorts.telehealth.web)"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_EXTERNAL_URL=.*", "TELEHEALTH_EXTERNAL_URL=http://$($envConfig.Domains.telehealth):$($envConfig.Config.containerPorts.telehealth.web)"
                }
                
                # Add Telehealth external HTTPS URL if not present
                if (-not ($envContent -match "TELEHEALTH_EXTERNAL_HTTPS_URL=")) {
                    $envContent += "`r`nTELEHEALTH_EXTERNAL_HTTPS_URL=https://$($envConfig.Domains.telehealth):$($envConfig.Config.containerPorts.telehealth.https)"
                } else {
                    $envContent = $envContent -replace "TELEHEALTH_EXTERNAL_HTTPS_URL=.*", "TELEHEALTH_EXTERNAL_HTTPS_URL=https://$($envConfig.Domains.telehealth):$($envConfig.Config.containerPorts.telehealth.https)"
                }

                # Write the updated content to the target file
                Set-Content -Path $envFilePath -Value $envContent -Force
                Write-Host "Created/Updated .env file at: $envFilePath" -ForegroundColor Green
            }
            catch {
                Write-Host "Error creating .env file from template: $_" -ForegroundColor Red
                # Fall back to basic template if there's an error
                CreateBasicEnvFile
            }
        }
        else {
            # Fall back to basic template if .env.example is not found
            Write-Host "OpenEMR .env.example file not found, creating a basic one..." -ForegroundColor Yellow
            CreateBasicEnvFile
        }
        
        # Function to create a basic .env file
        function CreateBasicEnvFile {
            $envFileContent = @"
# Environment file for Official OpenEMR - $Environment
# Generated: $(Get-Date)

COMPOSE_PROJECT_NAME=$($envConfig.ProjectName)
HTTP_PORT=$httpPort
HTTPS_PORT=$httpsPort
DOMAIN=$($envConfig.Domains.openemr)
VC_API_URL=https://$($envConfig.Domains.telehealth)
VC_API=/api/videoconsultation?
VC_API_DATA=/api/videoconsultation/data?
VC_API_PORT=443
VC_API_TOKEN=$($envConfig.Config.containerPorts.telehealth.api_token)
"@
            
            Set-Content -Path $envFilePath -Value $envFileContent -Force
            Write-Host "Created basic .env file at $envFilePath" -ForegroundColor Green
        }
        
        Write-Host "Created .env file at $envFilePath" -ForegroundColor Green
    } else {
        Write-Host "Using existing docker-compose.yml for Official OpenEMR" -ForegroundColor Green
    }

    # Save current location
    $currentLocation = Get-Location
    
    # Change to the OpenEMR directory
    Set-Location -Path "$openemrPath"
} else {
    # For non-official projects
    $openemrTelesaludPath = "$openemrDir"

    if (-not (Test-Path -Path $openemrTelesaludPath)) {
        Write-Host "OpenEMR-Telesalud directory not found at $openemrTelesaludPath" -ForegroundColor Red
        Write-Host "Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
        return
    } else {
        # Use the OpenEMR-Telesalud directory
        Write-Host "Using OpenEMR-Telesalud directory at $openemrTelesaludPath" -ForegroundColor Green
        
        # Save current location
        $currentLocation = Get-Location
        
        # Change to the OpenEMR-Telesalud directory
        Set-Location -Path "$openemrTelesaludPath"
        
        # Check if docker-compose.yml file exists
        if (-not (Test-Path -Path "docker-compose.yml")) {
            Write-Host "Error: docker-compose.yml not found. Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
            return
        } else {
            Write-Host "Using existing docker-compose.yml for OpenEMR-Telesalud" -ForegroundColor Green
        }
    }
}



# Handle database volumes if needed
if ($RemoveVolumes) {
    $databaseVolume = "${baseProjectName}_databasevolume"
    $existingVolume = docker volume ls --format "{{.Name}}" | Where-Object { $_ -eq $databaseVolume }
    
    if ($existingVolume) {
        # Check if any containers are using the volume
        $containersUsingVolume = docker ps -a --filter "volume=${databaseVolume}" --format "{{.Names}}"
        
        if ($containersUsingVolume) {
            Write-Host "Stopping and removing containers using the database volume..." -ForegroundColor Yellow
            foreach ($container in $containersUsingVolume) {
                Write-Host "  - Stopping container: $container" -ForegroundColor Yellow
                docker stop $container | Out-Null
                docker rm $container | Out-Null
            }
        }
        
        Write-Host "Removing database volume to ensure a clean setup..." -ForegroundColor Yellow
        docker volume rm $databaseVolume | Out-Null
        Write-Host "Database volume removed successfully." -ForegroundColor Green
    }
}

# Ensure Docker networks exist before starting containers
Write-Host "Ensuring networks exist before starting containers..." -ForegroundColor Yellow
$frontendNetwork = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $envConfig.FrontendNetwork }
if (-not $frontendNetwork) {
    Write-Host "Creating frontend network: $($envConfig.FrontendNetwork)" -ForegroundColor Yellow
    docker network create $envConfig.FrontendNetwork
}

$proxyNetwork = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $envConfig.ProxyNetwork }
if (-not $proxyNetwork) {
    Write-Host "Creating proxy network: $($envConfig.ProxyNetwork)" -ForegroundColor Yellow
    docker network create $envConfig.ProxyNetwork
}

# Check if containers are already running
$existingContainers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^$baseProjectName-openemr" }

if ($existingContainers) {
    Write-Host "OpenEMR containers are already running. Restarting them to apply changes..." -ForegroundColor Yellow
    Invoke-DockerCompose -Command "restart" -WorkingDirectory (Get-Location).Path
} else {
    # Start containers
    Write-Host "Starting OpenEMR containers with docker-compose..." -ForegroundColor Green
    Invoke-DockerCompose -Command "up -d" -WorkingDirectory (Get-Location).Path
    
    # For non-official projects, run additional setup commands
    if ($Project -ne "official") {
        $containerName = "$baseProjectName-openemr-openemr-1"
        docker exec -it $containerName bash -c "cd /var/www/html && composer install --no-dev && npm install && npm run build && composer dump-autoload -o"
    }
    
    # Wait for MySQL to be ready if we're starting fresh
    if ($RemoveVolumes) {
        Write-Host "Waiting for MySQL to initialize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}

# Fix network connections to ensure all containers are properly connected
Write-Host "Fixing network connections for OpenEMR containers..." -ForegroundColor Yellow
if ($Environment) {
    & "$PSScriptRoot\fix-network-connections.ps1" -Environment $Environment -Component "openemr" -SourceReposDir $SourceReposDir -Project $Project
} else {
    & "$PSScriptRoot\fix-network-connections.ps1" -Component "openemr" -SourceReposDir $SourceReposDir -Project $Project
}

# Return to the original directory
Set-Location -Path $workingDirectory

# Check if hosts file has the required entries
Write-Host "Step 7: Hosts File Configuration" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "Checking hosts file configuration..." -ForegroundColor Yellow

# Get domains from environment config
$requiredEntries = @(
    "127.0.0.1 $($envConfig.Domains.openemr)",
    "127.0.0.1 $($envConfig.Domains.telehealth)",
    "127.0.0.1 $($envConfig.Domains.jitsi)"
)

$hostsFile = Get-Content -Path "C:\Windows\System32\drivers\etc\hosts"
$missingEntries = @()
foreach ($entry in $requiredEntries) {
    $found = $false
    foreach ($line in $hostsFile) {
        # Check if the line contains the domain we're looking for
        $domain = $entry.Split(' ')[1]
        if ($line -match "127\.0\.0\.1.*\s+$domain(\s|$)") {
            $found = $true
            break
        }
    }
    
    if (-not $found) {
        $missingEntries += $entry
    }
}

if ($missingEntries.Count -gt 0) {
    Write-Host "The following entries are missing from your hosts file:" -ForegroundColor Red
    foreach ($entry in $missingEntries) {
        Write-Host "  $entry" -ForegroundColor Red
    }
    Write-Host "Please run the following command as Administrator to update your hosts file:" -ForegroundColor Yellow
    Write-Host "Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value '`n$($missingEntries -join "`n")' -Force" -ForegroundColor Cyan
    
    $updateHosts = Get-UserInput "Would you like to create a script to update the hosts file? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

    if ($updateHosts -eq "y") {
        # Create PowerShell script for updating hosts file
        $psContent = @'
# Run this script as Administrator
param(
    [string]$Project = "{0}",
    [string]$Environment = "{1}",
    [string]$DomainBase = "{2}"
)

$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$entries = @"

# $Project-$Environment environment entries
127.0.0.1 $Environment-$Project.$DomainBase
127.0.0.1 vc-$Environment-$Project.$DomainBase
127.0.0.1 vcbknd-$Environment-$Project.$DomainBase
"@

Add-Content -Path $hostsFile -Value $entries -Force
Write-Host "Hosts file updated successfully!" -ForegroundColor Green
'@ -f $Project, $Environment, $DomainBase

        Set-Content -Path "update-hosts.ps1" -Value $psContent -Encoding utf8
        Write-Host "Script created: update-hosts.ps1" -ForegroundColor Green

        # Create BAT script for backward compatibility
        $batContent = "@echo off`r`necho Adding localhost entries to hosts file...`r`n"
        
        foreach ($entry in $missingEntries) {
            $batContent += "echo $entry >> %WINDIR%\System32\drivers\etc\hosts`r`n"
        }
        
        $batContent += "echo Hosts file updated successfully!`r`npause"
        
        Set-Content -Path "update-hosts.bat" -Value $batContent -Encoding utf8
        Write-Host "Script created: update-hosts.bat" -ForegroundColor Green
        Write-Host "Please run one of these scripts as Administrator:" -ForegroundColor Yellow
        Write-Host "  - update-hosts.ps1 (PowerShell script with parameters)" -ForegroundColor Yellow
        Write-Host "  - update-hosts.bat (Batch script for backward compatibility)" -ForegroundColor Yellow
    }
}


# Setup Jitsi
Write-Host "Step 6: Jitsi Setup" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "Setting up Jitsi..." -ForegroundColor Green

# Define the Jitsi path
$jitsiPath = $jitsiDir

if (-not (Test-Path -Path $jitsiPath)) {
    Write-Host "Jitsi directory not found at $jitsiPath" -ForegroundColor Red
    Write-Host "Please run backup-and-staging.ps1 first to create the environment." -ForegroundColor Red
    return
} else {
    Write-Host "Using Jitsi directory at: $jitsiPath" -ForegroundColor Green
}

# Ensure networks are created before starting Jitsi
Write-Host "Ensuring networks exist..." -ForegroundColor Yellow
if ($Environment) {
    & "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $Project -SourceReposDir $SourceReposDir -DomainBase $DomainBase
} else {
    & "$PSScriptRoot\network-setup.ps1" -Project $Project -SourceReposDir $SourceReposDir -DomainBase $DomainBase
}

# Check if Jitsi containers are already running
$existingJitsiContainers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^$baseProjectName-$JitsiFolder" }
if ($existingJitsiContainers) {
    Write-Host "Jitsi containers are already running. Skipping docker-compose up." -ForegroundColor Yellow
} else {
    # Save current location
    $currentLocation = Get-Location
    
    # Change to Jitsi directory
    Set-Location -Path $jitsiPath
    
    Write-Host "Building Jitsi containers..." -ForegroundColor Green
    Invoke-DockerCompose -Command "build" -WorkingDirectory (Get-Location).Path
    
    Write-Host "Starting Jitsi containers..." -ForegroundColor Green
    Invoke-DockerCompose -Command "up -d" -WorkingDirectory (Get-Location).Path
    
    # Return to previous location
    Set-Location -Path $currentLocation
}

# Fix network connections for Jitsi containers
Write-Host "Fixing network connections for Jitsi containers..." -ForegroundColor Yellow
if ($Environment) {
    & "$PSScriptRoot\fix-network-connections.ps1" -Environment $Environment -Component "jitsi" -SourceReposDir $SourceReposDir -Project $Project
} else {
    & "$PSScriptRoot\fix-network-connections.ps1" -Component "jitsi" -SourceReposDir $SourceReposDir -Project $Project
}

# WordPress Setup
Write-Host "-----------------" -ForegroundColor Cyan
Write-Host "WordPress Installation" -ForegroundColor Cyan

# Prompt for WordPress installation
$installWordPress = Get-UserInput "Do you want to install WordPress for the main site? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

if ($installWordPress -eq "y") {
    Write-Host "Setting up WordPress..." -ForegroundColor Green
    
    # Define the WordPress path
    $wordpressFolder = $envConfig.FolderNames.wordpress
    $wordpressPath = Join-Path -Path $baseDir -ChildPath "$($envConfig.DirectoryName)\$wordpressFolder"

    if (-not (Test-Path -Path $wordpressPath)) {
        Write-Host "Creating WordPress directory at: $wordpressPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $wordpressPath -Force | Out-Null
    } else {
        Write-Host "Using WordPress directory at: $wordpressPath" -ForegroundColor Green
    }

    # Copy docker-compose.yml template
    Write-Host "Copying WordPress docker-compose.yml template..." -ForegroundColor Yellow
    Copy-Item "$PSScriptRoot\templates\wordpress\docker-compose.yml" -Destination $wordpressPath -Force

    # Create WordPress .env file
    Write-Host "Creating WordPress .env file..." -ForegroundColor Yellow
    $wordpressEnvContent = @"
# WordPress Environment for $($envConfig.ProjectName)
# Generated: $(Get-Date -Format "MM/dd/yyyy HH:mm:ss")

COMPOSE_PROJECT_NAME=$($envConfig.ProjectName)-wordpress
HTTP_PORT=$($envConfig.Config.containerPorts.wordpress.http)
DB_PORT=$($envConfig.Config.containerPorts.wordpress.db)
PROJECT_NAME=$($envConfig.ProjectName)
"@

    Set-Content -Path "$wordpressPath\.env" -Value $wordpressEnvContent

    # Check if WordPress containers are already running
    $existingWordpressContainers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^$baseProjectName-$wordpressFolder" }
    if ($existingWordpressContainers) {
        Write-Host "WordPress containers are already running. Skipping docker-compose up." -ForegroundColor Yellow
    } else {
        # Save current location
        $currentLocation = Get-Location
        
        # Change to WordPress directory
        Set-Location -Path $wordpressPath
        
        Write-Host "Starting WordPress containers..." -ForegroundColor Green
        Invoke-DockerCompose -Command "up -d" -WorkingDirectory (Get-Location).Path
        
        # Wait a moment for the container to start
        Start-Sleep -Seconds 5
        
        # Copy the theme download script to the WordPress container
        $wordpressContainer = "$baseProjectName-$wordpressFolder-wordpress-1"
        Write-Host "Installing default WordPress themes..." -ForegroundColor Green
        
        # Create themes directory if it doesn't exist
        if (-not (Test-Path -Path "$wordpressPath\themes")) {
            New-Item -ItemType Directory -Path "$wordpressPath\themes" -Force | Out-Null
        }
        
        # Check if the medical theme repository exists in source-repos
        $medicalThemeSourceDir = "$PSScriptRoot\source-repos\development-medical-theme"
        if (Test-Path -Path $medicalThemeSourceDir) {
            Write-Host "Found medical theme repository at: $medicalThemeSourceDir" -ForegroundColor Green
            
            # Copy the medical theme to the WordPress themes directory
            Write-Host "Copying medical theme to WordPress themes directory..." -ForegroundColor Yellow
            $medicalThemeTargetDir = "$wordpressPath\themes\medical-theme"
            
            # Create the target directory if it doesn't exist
            if (-not (Test-Path -Path $medicalThemeTargetDir)) {
                New-Item -ItemType Directory -Path $medicalThemeTargetDir -Force | Out-Null
            }
            
            # Function to selectively copy WordPress theme files
            function Copy-WordPressThemeFiles {
                param (
                    [string]$SourceDir,
                    [string]$TargetDir
                )
                
                # Create target directory if it doesn't exist
                if (-not (Test-Path -Path $TargetDir)) {
                    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
                }
                
                # Define files and directories to include
                $includePaths = @(
                    # PHP files
                    "*.php",
                    # CSS files
                    "*.css",
                    # Built JavaScript
                    "assets\js-build\*",
                    # Images
                    "assets\images\*",
                    # Fonts
                    "assets\fonts\*",
                    # Theme configuration
                    "theme.json",
                    "screenshot.png",
                    "style.css",
                    # Template parts
                    "template-parts\*",
                    # Include directories
                    "inc\*"
                )
                
                # Define paths to explicitly exclude
                $excludePaths = @(
                    # Development files
                    "node_modules",
                    ".git",
                    ".github",
                    ".vscode",
                    # Source files that get compiled
                    "assets\js-src",
                    "assets\scss",
                    # Build configuration
                    "package.json",
                    "package-lock.json",
                    "webpack.config.js",
                    "gulpfile.js",
                    # Map files
                    "*.map"
                )
                
                # Copy only the included paths
                foreach ($path in $includePaths) {
                    $sourcePath = Join-Path -Path $SourceDir -ChildPath $path
                    if (Test-Path -Path $sourcePath) {
                        # Get the parent directory for the target
                        $targetParent = Split-Path -Path (Join-Path -Path $TargetDir -ChildPath $path)
                        
                        # Create parent directory if it doesn't exist
                        if (-not (Test-Path -Path $targetParent)) {
                            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
                        }
                        
                        # Copy the files
                        Copy-Item -Path $sourcePath -Destination (Join-Path -Path $TargetDir -ChildPath (Split-Path -Path $path)) -Recurse -Force
                    }
                }
                
                Write-Host "WordPress theme files copied selectively to: $TargetDir" -ForegroundColor Green
            }
            
            # Selectively copy only the necessary theme files
            Copy-WordPressThemeFiles -SourceDir $medicalThemeSourceDir -TargetDir $medicalThemeTargetDir
            Write-Host "Medical theme copied successfully" -ForegroundColor Green
        } else {
            Write-Host "Medical theme repository not found at: $medicalThemeSourceDir" -ForegroundColor Yellow
            Write-Host "Run backup-and-staging.ps1 with repository updates to download the theme" -ForegroundColor Yellow
        }
        
        # Download and install default WordPress themes directly on the host
        Write-Host "Downloading default WordPress themes..." -ForegroundColor Green
        
        # Define theme URLs - always using the latest versions
        $themeUrls = @(
            "https://downloads.wordpress.org/theme/twentytwentyfour.zip",
            "https://downloads.wordpress.org/theme/astra.zip",
            "https://downloads.wordpress.org/theme/kadence.zip"
        )
        
        # Create a temporary directory for downloads
        $tempDir = "$env:TEMP\wp-themes-temp"
        if (-not (Test-Path -Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }
        
        # Download and extract each theme
        foreach ($themeUrl in $themeUrls) {
            $themeName = [System.IO.Path]::GetFileNameWithoutExtension($themeUrl)
            $zipPath = "$tempDir\$themeName.zip"
            $extractPath = "$wordpressPath\themes"
            
            Write-Host "Downloading $themeName theme..." -ForegroundColor Yellow
            try {
                # Download the theme
                Invoke-WebRequest -Uri $themeUrl -OutFile $zipPath
                
                # Extract the theme to the WordPress themes directory
                Write-Host "Extracting $themeName theme..." -ForegroundColor Yellow
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                
                Write-Host "$themeName theme installed successfully" -ForegroundColor Green
            } catch {
                Write-Host "Failed to download or extract $themeName theme: $_" -ForegroundColor Red
            } finally {
                # Clean up the zip file
                if (Test-Path -Path $zipPath) {
                    Remove-Item -Path $zipPath -Force
                }
            }
        }
        
        # Clean up the temporary directory
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
        
        Write-Host "Default WordPress themes installed successfully" -ForegroundColor Green
        
        # Return to previous location
        Set-Location -Path $currentLocation
    }
    
    # Configure NPM to route main domain to WordPress
    Write-Host "Configuring Nginx Proxy Manager to route main domain to WordPress..." -ForegroundColor Yellow
    # This is now handled automatically in configure-npm.ps1
    Write-Host "NPM will be configured to route:" -ForegroundColor Green
    Write-Host "  - Base domain ($DomainBase) to WordPress" -ForegroundColor Green
    Write-Host "  - $($envConfig.Domains.openemr) to OpenEMR" -ForegroundColor Green
    Write-Host "  - $($envConfig.Domains.telehealth) to Telehealth" -ForegroundColor Green
    Write-Host "  - $($envConfig.Domains.jitsi) to Jitsi" -ForegroundColor Green
} else {
    Write-Host "Skipping WordPress installation." -ForegroundColor Yellow
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

# Network Setup
Write-Host "Setting up Docker networks..." -ForegroundColor Cyan

# Create shared network if it doesn't exist
$sharedNetworkName = "$Project-shared-network"
$sharedNetworkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $sharedNetworkName }

if (-not $sharedNetworkExists) {
    Write-Host "Creating shared network: $sharedNetworkName" -ForegroundColor Yellow
    docker network create $sharedNetworkName
} else {
    Write-Host "Shared network already exists: $sharedNetworkName" -ForegroundColor Green
}

# Create environment-specific network if it doesn't exist
$envNetworkName = "$baseProjectName-network"
$envNetworkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $envNetworkName }

if (-not $envNetworkExists) {
    Write-Host "Creating environment network: $envNetworkName" -ForegroundColor Yellow
    docker network create $envNetworkName
} else {
    Write-Host "Environment network already exists: $envNetworkName" -ForegroundColor Green
}

# Connect containers to appropriate networks
if ($OpenEMRContainer) {
    Write-Host "Connecting OpenEMR to networks..." -ForegroundColor Yellow
    docker network connect $envNetworkName $OpenEMRContainer
    docker network connect $sharedNetworkName $OpenEMRContainer
}

if ($TelehealthAppContainer) {
    Write-Host "Connecting Telehealth App to networks..." -ForegroundColor Yellow
    docker network connect $envNetworkName $TelehealthAppContainer
    docker network connect $sharedNetworkName $TelehealthAppContainer
}

if ($TelehealthWebContainer) {
    Write-Host "Connecting Telehealth Web to networks..." -ForegroundColor Yellow
    docker network connect $envNetworkName $TelehealthWebContainer
    docker network connect $sharedNetworkName $TelehealthWebContainer
}

if ($JitsiContainer) {
    Write-Host "Connecting Jitsi to networks..." -ForegroundColor Yellow
    if ($JitsiContainer -like "*jitsi-docker*") {
        # For shared Jitsi instance, only connect to shared network
        docker network connect $sharedNetworkName $JitsiContainer
    } else {
        # For environment-specific Jitsi instance, connect to both networks
        docker network connect $envNetworkName $JitsiContainer
        docker network connect $sharedNetworkName $JitsiContainer
    }
}

# Configure NPM network connections
$fixNpmNetwork = Get-UserInput "Do you want to configure NPM network connections? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

if ($fixNpmNetwork -eq "y") {
    Write-Host "Configuring NPM network connections..." -ForegroundColor Green
    if ($Environment) {
        & "$PSScriptRoot\fix-npm-network.ps1" -Environment $Environment -Project $Project
    } else {
        & "$PSScriptRoot\fix-npm-network.ps1" -Project $Project
    }
    Write-Host "NPM network connections have been configured." -ForegroundColor Green
} else {
    Write-Host "Skipping NPM network connection configuration." -ForegroundColor Yellow
}

# Configure NPM
$configureNPM = Get-UserInput "Do you want to configure Nginx Proxy Manager? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

if ($configureNPM -eq "y") {
    # Get NPM URL from environment config
    $npmAdminPort = $envConfig.NpmPorts.admin
    $npmUrl = "http://localhost:$npmAdminPort"
    Write-Host "Using NPM URL: $npmUrl" -ForegroundColor Cyan

    # First ask about SSL certificates
    $uploadSSL = Get-UserInput "Do you want to upload SSL certificates to Nginx Proxy Manager? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
    $certificateId = $null

    if ($uploadSSL -eq "y") {
        # Call selenium-ssl.ps1 to set up SSL certificates and get the certificate ID
        Write-Host "Configuring SSL certificates using Selenium..." -ForegroundColor Cyan
        
        # Check if we're using a non-localhost domain and explicitly pass UseLetsEncrypt
        if ($DomainBase -ne "localhost") {
            Write-Host "Non-localhost domain detected: $DomainBase." -ForegroundColor Green
            
            # Check if Let's Encrypt certificates already exist
            $letsEncryptPath = Join-Path $deploymentFolderPath "proxy\letsencrypt"
            $letsEncryptExists = Test-Path $letsEncryptPath
            $letsEncryptCertsExist = $false
            
            if ($letsEncryptExists) {
                # Check if there are actual certificate files in the Let's Encrypt directory
                $certFiles = Get-ChildItem -Path $letsEncryptPath -Recurse -Include "*.pem", "*.crt" -ErrorAction SilentlyContinue
                $letsEncryptCertsExist = ($certFiles -and $certFiles.Count -gt 0)
                
                if ($letsEncryptCertsExist) {
                    Write-Host "Found existing Let's Encrypt certificates at: $letsEncryptPath" -ForegroundColor Green
                    Write-Host "Skipping Let's Encrypt certificate creation to avoid rate limits." -ForegroundColor Yellow
                } else {
                    Write-Host "Let's Encrypt directory exists but no certificate files found." -ForegroundColor Yellow
                }
            } else {
                Write-Host "No existing Let's Encrypt certificates found." -ForegroundColor Yellow
            }
            
            # Determine whether to use Let's Encrypt based on existing certificates
            $useLetsEncrypt = -not $letsEncryptCertsExist
            
            # For non-localhost domains, we only need to call selenium-ssl.ps1 once
            # The script will internally create both self-signed and Let's Encrypt certificates if needed
            if ($useLetsEncrypt) {
                Write-Host "Creating both self-signed and Let's Encrypt certificates..." -ForegroundColor Cyan
                $sslOutput = & "$PSScriptRoot\selenium-ssl.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase -NpmUrl $npmUrl -UseLetsEncrypt
            } else {
                Write-Host "Creating only self-signed certificates (Let's Encrypt certificates already exist)..." -ForegroundColor Cyan
                $sslOutput = & "$PSScriptRoot\selenium-ssl.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase -NpmUrl $npmUrl
            }
            
            # Extract certificate ID from the output
            $certificateId = $null
            foreach ($line in $sslOutput) {
                if ($line -match "CERTIFICATE_ID=(\d+)") {
                    $certificateId = $matches[1]
                    Write-Host "Found certificate ID: $certificateId" -ForegroundColor Green
                    break
                }
            }
            
            # For testing, we'll use the first certificate ID found (self-signed)
            # instead of the Let's Encrypt certificate
            if ($certificateId) {
                Write-Host "Using self-signed certificate ID: $certificateId" -ForegroundColor Green
                Write-Host "Note: Using self-signed certificate as primary for testing purposes" -ForegroundColor Yellow
            }
        } else {
            # For localhost, just create self-signed certificates
            Write-Host "Using localhost domain. Creating self-signed certificates only." -ForegroundColor Yellow
            $sslOutput = & "$PSScriptRoot\selenium-ssl.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase -NpmUrl $npmUrl
        }
        
        # Extract the certificate ID from the output
        foreach ($line in $sslOutput) {
            if ($line -match "CERTIFICATE_ID=(\d+)") {
                $certificateId = $matches[1]
                Write-Host "Found Certificate ID: $certificateId" -ForegroundColor Green
                break
            }
        }
    } else {
        Write-Host "Skipping SSL certificate upload." -ForegroundColor Yellow
    }

    # Configure NPM hosts
    Write-Host "Configuring Nginx Proxy Manager hosts..." -ForegroundColor Cyan
    if ($certificateId) {
        & "$PSScriptRoot\configure-npm.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase -NpmUrl $npmUrl -Force -certificate_id $certificateId
    } else {
        Write-Host "No certificate ID found, configuring without specific certificate ID" -ForegroundColor Yellow
        & "$PSScriptRoot\configure-npm.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase -NpmUrl $npmUrl -Force
    }

} else {
    Write-Host "Skipping Nginx Proxy Manager configuration." -ForegroundColor Yellow
}

# Note: We no longer copy certificates to Jitsi and OpenEMR containers as SSL termination is now handled exclusively by Nginx Proxy Manager
Write-Host "SSL termination is now handled exclusively by Nginx Proxy Manager." -ForegroundColor Green
Write-Host "Certificates are only required in the Telehealth container for internal use." -ForegroundColor Green

# Change from automatic to Y/N prompt for Nginx SSL conflicts fix
Write-Host "Step 10: Fix Nginx SSL Conflicts" -ForegroundColor Cyan
Write-Host "-------------------------------" -ForegroundColor Cyan

# Show the SSL conflicts prompt for production environments
if ($Environment -eq "production") {
    $defaultSslResponse = if ($NonInteractive) { "y" } else { "n" }
    $fixNginxSsl = Get-UserInput "Do you want to fix Nginx SSL conflicts? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"

    if ($fixNginxSsl -eq "y") {
        Write-Host "Fixing Nginx SSL conflicts..." -ForegroundColor Green
        $fixNginxSslCommand = "$workingDirectory\fix-nginx-ssl-conflicts.ps1 -Environment $Environment"
        Invoke-Expression $fixNginxSslCommand
        Write-Host "Nginx SSL conflicts have been fixed." -ForegroundColor Green
    } else {
        Write-Host "Skipping Nginx SSL conflicts fix." -ForegroundColor Yellow
    }
} else {
    Write-Host "Skipping Nginx SSL conflicts check (not needed for non-production environment)." -ForegroundColor Green
}

# Final steps and summary
Write-Host "Step 12: Setup Complete" -ForegroundColor Cyan
Write-Host "-------------------" -ForegroundColor Cyan
Write-Host "The All-In-One Telehealth Platform setup is complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Summary of actions:" -ForegroundColor Yellow
Write-Host "1. Environment detected: $(if ($Environment) { (Get-Culture).TextInfo.ToTitleCase($Environment) } else { 'Production' })" -ForegroundColor White
Write-Host "2. Docker networks created/verified" -ForegroundColor White
Write-Host "3. NPM network connections configured (if requested)" -ForegroundColor White
Write-Host "4. OpenEMR setup completed" -ForegroundColor White
Write-Host "5. Telehealth setup completed" -ForegroundColor White
Write-Host "6. Certificates configured" -ForegroundColor White
Write-Host "7. Nginx Proxy Manager configured (if requested)" -ForegroundColor White
Write-Host "8. Database volumes: $(if ($RemoveVolumes) { 'Removed and recreated' } else { 'Preserved existing data' })" -ForegroundColor White
Write-Host ""

# Debug info for domain setup
Write-Host "Debug: DomainBase parameter = $DomainBase" -ForegroundColor Magenta

# Ensure domains are set correctly based on DomainBase parameter
if (-not $envConfig) { $envConfig = @{} }
if (-not $envConfig.Domains) { $envConfig.Domains = @{} }
if (-not $envConfig.ContainerPorts) { $envConfig.ContainerPorts = @{openemr=@{}} }
if (-not $envConfig.NpmPorts) { $envConfig.NpmPorts = @{} }

# Set domains explicitly based on the DomainBase parameter
$prefix = $Environment.ToLower()
if ($DomainBase -ne "localhost") {
    # This ensures domains are set correctly regardless of how environment-config.ps1 is loaded
    Write-Host "Debug: Explicitly setting domains with $DomainBase" -ForegroundColor Magenta
    $envConfig.Domains.openemr = "$prefix-$Project.$DomainBase"
    $envConfig.Domains.telehealth = "vc-$prefix-$Project.$DomainBase"
    $envConfig.Domains.jitsi = "vcbknd-$prefix-$Project.$DomainBase"
    $envConfig.Domains.wordpress = "$prefix-$Project.$DomainBase"
    $envConfig.Domains.npm = "npm-$prefix-$Project.$DomainBase"

}

Write-Host "Debug: Resulting domains:" -ForegroundColor Magenta
Write-Host "  openemr = $($envConfig.Domains.openemr)" -ForegroundColor Magenta
Write-Host "  telehealth = $($envConfig.Domains.telehealth)" -ForegroundColor Magenta
Write-Host "  jitsi = $($envConfig.Domains.jitsi)" -ForegroundColor Magenta
Write-Host "  wordpress = $($envConfig.Domains.wordpress)" -ForegroundColor Magenta
Write-Host "  npm = $($envConfig.Domains.npm)" -ForegroundColor Magenta

Write-Host "`nAccess Information:" -ForegroundColor Yellow
# Using consistent domain naming for all URLs
Write-Host "- OpenEMR Direct Access: http://$($envConfig.Domains.openemr):$($envConfig.ContainerPorts.openemr.http)" -ForegroundColor Green
Write-Host "- OpenEMR via NPM: https://$($envConfig.Domains.openemr):$($envConfig.NpmPorts.https)" -ForegroundColor Green
Write-Host "- Telehealth via NPM: https://$($envConfig.Domains.telehealth):$($envConfig.NpmPorts.https)" -ForegroundColor Green
Write-Host "- Nginx Proxy Manager Admin: http://$($envConfig.Domains.npm):$($envConfig.NpmPorts.admin)" -ForegroundColor Green
Write-Host "- WordPress: http://$($envConfig.Domains.wordpress):$($envConfig.ContainerPorts.wordpress.http)" -ForegroundColor Green
Write-Host "- WordPress via NPM: https://$($envConfig.Domains.wordpress):$($envConfig.NpmPorts.https)" -ForegroundColor Green
Write-Host "- Jitsi: https://$($envConfig.Domains.jitsi):$($envConfig.ContainerPorts.jitsi.http)" -ForegroundColor Green
Write-Host "- Jitsi via NPM: https://$($envConfig.Domains.jitsi):$($envConfig.NpmPorts.https)" -ForegroundColor Green
Write-Host "- NPM HTTP Port: $($envConfig.NpmPorts.http)" -ForegroundColor Green
Write-Host "- NPM HTTPS Port: $($envConfig.NpmPorts.https)" -ForegroundColor Green
Write-Host ""
Write-Host "Important notes:" -ForegroundColor Yellow
Write-Host "- When accessing through NPM, always include the port number: :$($envConfig.NpmPorts.https)" -ForegroundColor Yellow
Write-Host "- To shut down all containers, rerun setup.ps1 and answer 'y' to the cleanup questions" -ForegroundColor Yellow
Write-Host "- To remove database volumes during shutdown, use the -RemoveVolumes parameter" -ForegroundColor Yellow
Write-Host "- To remove all containers and volumes, use the -RemoveContainers and -RemoveVolumes parameters" -ForegroundColor Yellow
Write-Host "For any issues with database corruption, run: ./setup.ps1 -RemoveVolumes" -ForegroundColor Yellow
Write-Host "---------------------------------"
Write-Host "For production environments, the HTTP/HTTPS ports (80/443) are NOT offset based on project"
Write-Host "Only the admin port gets the offset (81 becomes 181 for jmdurant)"
Write-Host "This is why the jmdurant-production NPM uses ports 80/443 directly"
Write-Host "This is intentionally coded in your environment-config.ps1 to NOT adjust production HTTP/HTTPS ports, which means you can only run one production environment at a time."
Write-Host "The fix: Remove the if ($Environment -ne "production") condition so all environments (including production) use offset ports. This would allow you to run multiple production environments simultaneously."

Write-Host ""
Write-Host "Missing scripts detected:" -ForegroundColor Yellow
$missingScripts = @()
if (-not (Test-ScriptExists -ScriptName "generate-certs.ps1")) { $missingScripts += "generate-certs.ps1" }
if (-not (Test-ScriptExists -ScriptName "configure-npm.ps1")) { $missingScripts += "configure-npm.ps1" }
if (-not (Test-ScriptExists -ScriptName "fix-nginx-ssl-conflicts.ps1")) { $missingScripts += "fix-nginx-ssl-conflicts.ps1" }
if (-not (Test-ScriptExists -ScriptName "fix-npm-network.ps1")) { $missingScripts += "fix-npm-network.ps1" }

if ($missingScripts.Count -gt 0) {
    foreach ($script in $missingScripts) {
        Write-Host "- $script" -ForegroundColor White
    }
    Write-Host "Please create these scripts to enable full functionality." -ForegroundColor White
} else {
    Write-Host "All required scripts are present." -ForegroundColor White
}

Write-Host ""
Write-Host "Thank you for using the All-In-One Telehealth Platform setup script!" -ForegroundColor Green
Write-Host "For OpenEMR, the default login credentials are:" -ForegroundColor Yellow
Write-Host "Username : admin" -ForegroundColor Yellow
Write-Host "Password : AdminOps2023**" -ForegroundColor Yellow
Write-Host ""
#Write-Host "Press any key to continue..." -ForegroundColor Cyan
#$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# Function to fix OpenEMR database encryption key issues
function Fix-OpenEMRDatabase {
    param (
        [string]$Environment,
        [string]$ProjectName
    )
    
    Write-Host "Fixing OpenEMR database encryption keys for environment: $Environment" -ForegroundColor Yellow
    
    # Try to find the OpenEMR container
    $containerPattern = "$ProjectName-openemr-openemr-1"
    $containerExists = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $containerPattern }
    
    if (-not $containerExists) {
        Write-Host "OpenEMR container not found ($containerPattern). Please start the environment first." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found OpenEMR container: $containerPattern" -ForegroundColor Green

    # Step 1: Remove the filesystem encryption key files
    Write-Host "Removing existing encryption key files..." -ForegroundColor Cyan
    docker exec $containerPattern rm -f /var/www/html/sites/default/documents/logs_and_misc/methods/sixa /var/www/html/sites/default/documents/logs_and_misc/methods/sixb
    
    # Step 2: Truncate the keys table in the database
    Write-Host "Truncating the keys table in the database..." -ForegroundColor Cyan
    docker exec $containerPattern php -r 'try { $conn = new PDO("mysql:host=mysql;dbname=openemr", "root", "root"); $stmt = $conn->query("TRUNCATE TABLE `keys`"); echo "Keys table truncated successfully.\n"; } catch(PDOException $e) { echo "Error: " . $e->getMessage(); }'
    
    # Step 3: Restart the OpenEMR container to regenerate the keys
    Write-Host "Restarting OpenEMR container to regenerate encryption keys..." -ForegroundColor Yellow
    docker restart $containerPattern
    Start-Sleep -Seconds 5 # Wait for container to fully start
    
    Write-Host "OpenEMR encryption keys have been reset." -ForegroundColor Green
}

# Function to handle post-startup configuration of OpenEMR
function Configure-OpenEMR {
    param (
        [string]$Environment,
        [string]$ProjectName
    )
    
    Write-Host "Configuring OpenEMR for environment: $Environment" -ForegroundColor Yellow
    
    # Try to find the OpenEMR container
    $containerPattern = "$ProjectName-openemr-openemr-1"
    $mysqlContainer = "$ProjectName-openemr-mysql-1"
    $containerExists = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $containerPattern }
    
    if (-not $containerExists) {
        Write-Host "OpenEMR container not found ($containerPattern). Please start the environment first." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found OpenEMR container: $containerPattern" -ForegroundColor Green

    # Ensure necessary permissions
    Write-Host "Setting permissions..." -ForegroundColor Cyan
    docker exec $containerPattern chmod 666 /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern chmod -R 777 /var/www/html/sites/default/documents
    docker exec $containerPattern chown -R www-data:www-data /var/www/html/sites/default

    # Check if sqlconf.php exists and remove it if it does (force recreation)
    Write-Host "Checking for existing sqlconf.php..." -ForegroundColor Cyan
    docker exec $containerPattern test -f /var/www/html/sites/default/sqlconf.php
    $sqlconfExistsCode = $LASTEXITCODE
    
    if ($sqlconfExistsCode -eq 0) {
        Write-Host "Existing sqlconf.php found. Removing to ensure fresh configuration..." -ForegroundColor Yellow
        docker exec $containerPattern rm /var/www/html/sites/default/sqlconf.php
    } else {
        Write-Host "No existing sqlconf.php found." -ForegroundColor Green
    }

    # Create sqlconf.php from the sample file
    Write-Host "Creating sqlconf.php from sample..." -ForegroundColor Yellow
    docker exec $containerPattern bash -c "if [ -f /var/www/html/sites/default/sqlconf.sample.php ]; then cp /var/www/html/sites/default/sqlconf.sample.php /var/www/html/sites/default/sqlconf.php; else echo 'sqlconf.sample.php not found!'; exit 1; fi"
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -ne 0) {
         Write-Host "Error: Failed to copy sqlconf.sample.php in container $containerPattern." -ForegroundColor Red
         return
    }
    docker exec $containerPattern chmod 666 /var/www/html/sites/default/sqlconf.php

    # Update database connection details
    Write-Host "Updating database connection details in sqlconf.php..." -ForegroundColor Cyan
    docker exec $containerPattern sed -i 's/\$host.*;/\$host = "mysql";/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$port.*;/\$port = "3306";/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$login.*;/\$login = "openemr";/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$pass.*;/\$pass = "openemr";/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$dbase.*;/\$dbase = "openemr";/' /var/www/html/sites/default/sqlconf.php
    
    # Set the config variable to 0 initially (setup needs to run)
    Write-Host "Setting initial config value in sqlconf.php..." -ForegroundColor Cyan
    docker exec $containerPattern sed -i 's/\$config\s*=\s*0;/\$config = 1;/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$config\s*=\s*1;/\$config = 1;/' /var/www/html/sites/default/sqlconf.php # Ensure it's 1 if it was already 1
    #docker exec $mysqlContainer mysql -u root -proot -e "DROP DATABASE IF EXISTS openemr;"
    Write-Host "sqlconf.php created and configured in OpenEMR container" -ForegroundColor Green
    
    # Restart OpenEMR to apply changes
    Write-Host "Restarting OpenEMR container to apply changes..." -ForegroundColor Yellow
    docker restart $containerPattern
    Write-Host "OpenEMR container restarted" -ForegroundColor Green
    
    Write-Host "OpenEMR configuration attempt complete." -ForegroundColor Green
    
    # Check if Composer dependencies are installed
    # Write-Host "Checking Composer dependencies..." -ForegroundColor Cyan
    # docker exec $containerPattern test -d /var/www/html/vendor
    # $vendorExistsCode = $LASTEXITCODE
    # 
    # if ($vendorExistsCode -ne 0) {
    #     Write-Host "Composer dependencies not found. Installing..." -ForegroundColor Yellow
    #     docker exec $containerPattern composer install --working-dir=/var/www/html --no-interaction --no-plugins --no-scripts --prefer-dist
    #     Write-Host "Composer dependencies installed" -ForegroundColor Green
    # } else {
    #      Write-Host "Composer dependencies already exist." -ForegroundColor Green
    # }

    # Always run composer install for testing consistency
    Write-Host "Running composer install to ensure dependencies are up-to-date..." -ForegroundColor Yellow
    docker exec $containerPattern composer install --working-dir=/var/www/html --no-dev
    docker exec $containerPattern npm install
    docker exec $containerPattern npm run build
    docker exec $containerPattern composer dump-autoload -o
    $composerExitCode = $LASTEXITCODE
    if ($composerExitCode -ne 0) {
        Write-Host "Error: Composer install failed with exit code $composerExitCode" -ForegroundColor Red
    } else {
        Write-Host "Composer install completed." -ForegroundColor Green
        # Optional: Ensure web server owns the files AFTER composer runs (may need www-data:www-data depending on container setup)
        Write-Host "Attempting to set vendor directory ownership for web server..." -ForegroundColor Cyan
        docker exec $containerPattern chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.lock
        docker exec $containerPattern bash -c "mkdir -p /var/www/html/interface/modules/custom_modules/ && chown www-data:www-data /var/www/html/interface/modules/custom_modules/"
        docker restart $containerPattern
        $chownExitCode = $LASTEXITCODE
        if ($chownExitCode -ne 0) {
             Write-Host "Warning: Failed to set ownership on vendor directory (might be okay if running as root). Exit code: $chownExitCode" -ForegroundColor Yellow
        }
    }

    # Ensure Nginx rewrite rules are present
    Write-Host "Checking Nginx rewrite rules for Zend, Portal, API, OAuth2..." -ForegroundColor Cyan
    $nginxConfPath = Join-Path $PSScriptRoot "$ProjectName/openemr/dockerfiles/dev/openemr.conf"
    if (-not (Test-Path $nginxConfPath)) {
        Write-Host "Error: Nginx config file not found at $nginxConfPath" -ForegroundColor Red
    } else {
        # Check the current content
        $contentLines = Get-Content $nginxConfPath
        $hasServerBlock = $contentLines -match "server\s*{"
        
        # If the file doesn't have a server block, we assume it needs one
        if (-not $hasServerBlock) {
            Write-Host "Adding server block wrapper around existing rules..." -ForegroundColor Yellow
            
            # Preserve any existing content
            $existingContent = Get-Content -Path $nginxConfPath -Raw
            
            # Create a server block with the existing content inside
            $wrappedContent = @"
server {
    listen 80;
    server_name localhost;
    root /var/www/html;

    access_log  off;
    error_log   /dev/stdout;

    location / {
        index index.php;
        try_files `$uri `$uri/ /index.php?`$args;
    }

    location ~ \.php`$ {
        try_files `$uri =404;
        fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
    }

$existingContent
}
"@
            
            # Write the wrapped content back
            Set-Content -Path $nginxConfPath -Value $wrappedContent -Encoding UTF8
            Write-Host "Added server block wrapper to $nginxConfPath" -ForegroundColor Green
        } else {
            # The file already has a server block, check for the rewrite rules
            $nginxRules = @'
    if (!-e $request_filename) {
        # Needed for zend to work
        rewrite ^(.*/zend_modules/public)(.*) $1/index.php?$is_args$args last;
        # Needed for patient portal to work
        rewrite ^(.*/portal/patient)(.*) $1/index.php?_REWRITE_COMMAND=$1$2 last;
        # Needed for REST API/FHIR to work
        rewrite ^(.*/apis/)(.*) $1/dispatch.php?_REWRITE_COMMAND=$2 last;
        # Needed for OAuth2 to work
        rewrite ^(.*/oauth2/)(.*) $1/authorize.php?_REWRITE_COMMAND=$2 last;
    }
'@
            $marker = "# Needed for zend to work"
            
            $rulesExist = $contentLines -match [regex]::Escape($marker)
            
            if (-not $rulesExist) {
                Write-Host "Nginx rules not found. Adding them..." -ForegroundColor Yellow
                # Find the index of the last closing brace
                $lastBraceIndex = -1
                for ($i = $contentLines.Count - 1; $i -ge 0; $i--) {
                    if ($contentLines[$i].Trim() -eq "}") {
                        $lastBraceIndex = $i
                        break
                    }
                }
                
                if ($lastBraceIndex -ge 0) {
                    # Split the rules into lines and add indentation
                    $indentedRules = $nginxRules.Split([Environment]::NewLine) | ForEach-Object { "    " + $_ } | ForEach-Object { [string]$_ }
                    
                    # Create a new list and insert the rules
                    $newContent = [System.Collections.Generic.List[string]]::new()
                    $newContent.AddRange([string[]]($contentLines[0..($lastBraceIndex-1)]))
                    $newContent.AddRange([string[]]$indentedRules)
                    $newContent.Add($contentLines[$lastBraceIndex]) # Add the closing brace back
                    # Add any lines that might have been after the last brace (unlikely for nginx conf)
                    if ($lastBraceIndex + 1 -lt $contentLines.Count) {
                        $newContent.AddRange([string[]]($contentLines[($lastBraceIndex+1)..($contentLines.Count-1)]))
                    }
                    
                    # Write the modified content back
                    $newContent | Set-Content $nginxConfPath -Encoding UTF8
                    Write-Host "Nginx rules added successfully to $nginxConfPath" -ForegroundColor Green
                } else {
                    Write-Host "Error: Could not find the closing brace '}' for the server block in $nginxConfPath" -ForegroundColor Red
                }
            } else {
                Write-Host "Nginx rules already exist in $nginxConfPath. Skipping." -ForegroundColor Green
            }
        }
    }

    Write-Host "OpenEMR configuration process finished." -ForegroundColor Green
    Write-Host "You should now be able to access the setup page." -ForegroundColor Green
    Write-Host "OpenEMR is ready to use at: http://localhost:$($envConfig.Config.containerPorts.openemr.http)/" -ForegroundColor Green
}

# Function to fix issues in the Zend Module Installer view file
function Fix-OpenEMRModuleInstallerIssues {
    param (
        [string]$ProjectName
    )
    
    Write-Host "Fixing OpenEMR Module Installer issues..." -ForegroundColor Cyan
    
    # The container name might vary depending on the project configuration
    $containerName = "$ProjectName-openemr-openemr-1"
    
    # Check if container is running
    $containerRunning = docker ps -q --filter "name=$containerName" | Measure-Object | Select-Object -ExpandProperty Count
    
    if ($containerRunning -eq 0) {
        Write-Host "OpenEMR container is not running. Skipping module installer fixes." -ForegroundColor Yellow
        return $false
    }
    
    try {
        # Path to the file inside the container
        $filePath = "/var/www/html/interface/modules/zend_modules/module/Installer/view/installer/installer/index.phtml"
        
        # Fix 1: Correct the readdir function call - missing $ sign in variable name
        Write-Host "  - Fixing readdir function call..." -ForegroundColor Green
        docker exec $containerName sed -i 's/readdir(dpath)/readdir($handle)/g' $filePath
        
        # Fix 2: Correct the closedir function call - using path instead of handle
        Write-Host "  - Fixing closedir function call..." -ForegroundColor Green
        docker exec $containerName sed -i 's/closedir($dpath)/closedir($handle)/g' $filePath
        
        # Restart PHP-FPM to apply changes
        Write-Host "  - Restarting PHP-FPM service..." -ForegroundColor Green
        docker exec $containerName service php8.1-fpm restart
        
        Write-Host "OpenEMR Module Installer fixes applied successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error fixing OpenEMR Module Installer: $_" -ForegroundColor Red
        return $false
    }
}

# Update container hosts for localhost domains
if ($DomainBase -eq "localhost") {
    Write-Host "Updating container hosts for localhost domains..." -ForegroundColor Cyan
    try {
        & "$PSScriptRoot\update-container-hosts.ps1"
        Write-Host "Container hosts updated successfully." -ForegroundColor Green
    } catch {
        Write-Host "Warning: Failed to update container hosts: $_" -ForegroundColor Yellow
        Write-Host "Continuing with deployment..." -ForegroundColor Yellow
    }
}

# Function to create a zip file of the entire deployment
function Zip-Deployment {
    param (
        [string]$ProjectName,
        [string]$Environment
    )
    
    Write-Host "Creating zip archive of deployment..." -ForegroundColor Cyan
    
    # Create timestamp for zip file name
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    # Since ProjectName already includes the environment (e.g., "official-staging"),
    # we don't need to append the environment again
    $zipFileName = "$ProjectName-$timestamp.zip"
    $zipFilePath = Join-Path $PSScriptRoot $zipFileName
    
    try {
        # The main deployment folder to include
        # Since ProjectName already includes the environment (e.g., "official-staging"),
        # we don't need to append the environment again
        $deploymentFolder = "$ProjectName"
        $deploymentFolderPath = Join-Path $PSScriptRoot $deploymentFolder
        
        # Debug output to verify the path we're looking for
        Write-Host "Looking for deployment folder at: $deploymentFolderPath" -ForegroundColor Yellow
        
        if (-not (Test-Path -Path $deploymentFolderPath)) {
            Write-Host "Deployment folder not found at: $deploymentFolderPath" -ForegroundColor Red
            Write-Host "Please ensure the deployment was created correctly." -ForegroundColor Red
            return $false
        }
        
        Write-Host "Found deployment folder: $deploymentFolder" -ForegroundColor Green
        
        # Create a simplified zip that only includes the deployment folder itself
        Write-Host "  - Adding only the deployment folder to the zip" -ForegroundColor Yellow
        
        # Explicitly stop database/proxy containers to avoid file locking issues
        Write-Host "Stopping database containers to avoid file locking issues..." -ForegroundColor Yellow
        
        try {
            # Try to stop any database containers to avoid locks
            $dbContainerPattern = "$ProjectName-*-database-*"
            $proxyContainerPattern = "$ProjectName-proxy-*"
            
            Write-Host "Identifying running containers that may lock files..." -ForegroundColor Yellow
            $stoppedContainers = @()
            $containers = docker ps --format "{{.Names}}" | Where-Object { $_ -like $dbContainerPattern -or $_ -like $proxyContainerPattern }
            
            if ($containers) {
                Write-Host "Found containers that might lock database files:" -ForegroundColor Yellow
                $containers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                
                # Ask user if they want to stop these containers
                $stopContainers = Get-UserInput -Prompt "Do you want to stop these containers before creating the zip? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
                
                if ($stopContainers -eq "y") {
                    foreach ($container in $containers) {
                        Write-Host "Stopping container: $container" -ForegroundColor Yellow
                        docker stop $container
                        # Keep track of stopped containers so we can restart them later
                        $stoppedContainers += $container
                    }
                    # Give containers time to release file locks
                    Write-Host "Waiting for file locks to be released..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                } else {
                    Write-Host "Containers will remain running. The zip operation may fail if files are locked." -ForegroundColor Yellow
                }
            } else {
                Write-Host "No database or proxy containers found running." -ForegroundColor Green
            }
            
            # Special handling for Let's Encrypt certificate files
            $letsEncryptPath = Join-Path $deploymentFolderPath "proxy\letsencrypt"
            if (Test-Path $letsEncryptPath) {
                Write-Host "Let's Encrypt certificate directory found at: $letsEncryptPath" -ForegroundColor Yellow
                Write-Host "Ensuring certificate files are accessible..." -ForegroundColor Yellow
                
                # Add a small delay to ensure file locks are released
                Start-Sleep -Seconds 5
                
                # Try to temporarily set permissions to ensure access
                try {
                    # This is a best-effort attempt and may fail, which is fine
                    Get-ChildItem -Path $letsEncryptPath -Recurse -ErrorAction SilentlyContinue | 
                        ForEach-Object { 
                            try { $_.Attributes = $_.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly } catch { }
                        }
                    Write-Host "Certificate file permissions updated." -ForegroundColor Green
                } catch {
                    Write-Host "Warning: Could not update certificate file permissions: $_" -ForegroundColor Yellow
                }
            }
            
            # Save the list of stopped containers for later restart
            $global:stoppedContainers = $stoppedContainers
        } catch {
            Write-Host "Warning: Could not check for running containers: $_" -ForegroundColor Yellow
            # Continue with the zip operation anyway
        }
        
        # Only include the deployment folder in the zip archive
        $fullPathToZip = Join-Path $PSScriptRoot $deploymentFolder
        
        # Copy and customize the start-deployment.sh script for the deployment folder
        $startupScriptSource = Join-Path $PSScriptRoot "templates\start-deployment.sh"
        $startupScriptDest = Join-Path $fullPathToZip "start-deployment.sh"
        
        if (Test-Path -Path $startupScriptSource) {
            Write-Host "Customizing startup script for deployment..." -ForegroundColor Green
            
            # Read the template content
            $content = Get-Content -Path $startupScriptSource -Raw
            
            # Get environment configuration
            if (-not $envConfig) {
                Write-Host "Loading environment configuration for script customization..." -ForegroundColor Yellow
                $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $ProjectName -DomainBase $DomainBase
            }
            
            # Replace placeholder variables with actual values
            $content = $content -replace "__DOMAIN_BASE__", $DomainBase
            $content = $content -replace "__PROJECT_NAME__", $ProjectName
            $content = $content -replace "__ENVIRONMENT__", $Environment
            $content = $content -replace "__NPM_ADMIN_PORT__", $envConfig.NpmPorts.admin
            $content = $content -replace "__NPM_HTTP_PORT__", $envConfig.NpmPorts.http
            $content = $content -replace "__NPM_HTTPS_PORT__", $envConfig.NpmPorts.https
            
            # Ensure the script has Unix-style line endings (LF instead of CRLF)
            $content = $content -replace "`r`n", "`n"
            
            # Write the customized content to the destination file
            [System.IO.File]::WriteAllText($startupScriptDest, $content)
            
            Write-Host "Startup script customized with the following values:" -ForegroundColor Green
            Write-Host "  - Domain Base: $DomainBase" -ForegroundColor Green
            Write-Host "  - Project Name: $ProjectName" -ForegroundColor Green
            Write-Host "  - Environment: $Environment" -ForegroundColor Green
            Write-Host "  - NPM Admin Port: $($envConfig.NpmPorts.admin)" -ForegroundColor Green
            Write-Host "  - NPM HTTP Port: $($envConfig.NpmPorts.http)" -ForegroundColor Green
            Write-Host "  - NPM HTTPS Port: $($envConfig.NpmPorts.https)" -ForegroundColor Green
            
            # Make the script executable (this won't have effect on Windows but will be preserved in the zip)
            if ($IsLinux -or $IsMacOS) {
                chmod +x $startupScriptDest
            }
        } else {
            Write-Host "Warning: Startup script template not found at $startupScriptSource" -ForegroundColor Yellow
        }
        
        # Create zip archive with the deployment folder, excluding only letsencrypt/live directory
        Write-Host "Creating zip archive with the deployment folder..." -ForegroundColor Green
        
        # Check if letsencrypt directory exists
        $letsEncryptPath = Join-Path $fullPathToZip "proxy\letsencrypt"
        $letsEncryptLivePath = Join-Path $letsEncryptPath "live"
        
        if (Test-Path $letsEncryptPath) {
            if (Test-Path $letsEncryptLivePath) {
                Write-Host "Excluding Let's Encrypt 'live' directory from zip file to avoid symlink issues..." -ForegroundColor Yellow
                
                # Create a new, empty zip file
                if (Test-Path $zipFilePath) { Remove-Item -Path $zipFilePath -Force }
                
                # Get all files recursively, excluding the letsencrypt/live directory
                $filesToZip = Get-ChildItem -Path $fullPathToZip -Recurse | 
                             Where-Object { $_.FullName -notlike "$letsEncryptLivePath\*" -and $_.FullName -ne $letsEncryptLivePath -and -not $_.PSIsContainer }
                
                # Create the zip file with these files, preserving the directory structure
                $filesToZip | Compress-Archive -DestinationPath $zipFilePath -Update
                
                # Create a README file explaining why letsencrypt/live is excluded
                $readmePath = Join-Path $env:TEMP "letsencrypt-live-readme.txt"
                Set-Content -Path $readmePath -Value "Let's Encrypt 'live' directory is not included in this zip file to avoid symlink issues. These files will be regenerated on the target server if needed."
                
                # Create the letsencrypt/live directory structure in the zip
                $liveDirRelativePath = "proxy\letsencrypt\live"
                $readmeInZipPath = Join-Path $liveDirRelativePath "README.txt"
                
                # Add the README to the zip in the letsencrypt/live directory
                Compress-Archive -Path $readmePath -Update -DestinationPath $zipFilePath -EntryPath $readmeInZipPath
                
                # Clean up
                Remove-Item -Path $readmePath -Force
                
                Write-Host "Created zip file with all files except the Let's Encrypt 'live' directory." -ForegroundColor Green
            } else {
                # If letsencrypt/live directory doesn't exist, just zip everything
                Write-Host "No Let's Encrypt 'live' directory found. Including all files in the zip." -ForegroundColor Green
                Compress-Archive -Path $fullPathToZip -DestinationPath $zipFilePath -Force
            }
        } else {
            # If letsencrypt directory doesn't exist, just zip everything
            Write-Host "No Let's Encrypt directory found. Including all files in the zip." -ForegroundColor Green
            Compress-Archive -Path $fullPathToZip -DestinationPath $zipFilePath -Force
        }
        
        # Get the size of the zip file
        $fileInfo = Get-Item $zipFilePath
        $fileSizeInMB = [Math]::Round($fileInfo.Length / 1MB, 2)
        
        Write-Host "Deployment archive created successfully: $zipFileName ($fileSizeInMB MB)" -ForegroundColor Green
        Write-Host "Archive location: $zipFilePath" -ForegroundColor Green
        Write-Host "You can use this archive to transfer the deployment to another server." -ForegroundColor Green
        
        # Display deployment instructions
        Write-Host "`nDeployment Instructions:" -ForegroundColor Cyan
        Write-Host "--------------------" -ForegroundColor Cyan
        Write-Host "1. Copy the zip file to your remote server:" -ForegroundColor White
        Write-Host "   scp $zipFileName username@remote-server:/path/to/destination/" -ForegroundColor Yellow
        Write-Host "`n2. On the remote server, extract the archive:" -ForegroundColor White
        Write-Host "   unzip $zipFileName" -ForegroundColor Yellow
        Write-Host "`n3. Navigate to the extracted directory:" -ForegroundColor White
        Write-Host "   cd $deploymentFolder" -ForegroundColor Yellow
        Write-Host "`n4. Make the startup script executable:" -ForegroundColor White
        Write-Host "   chmod +x start-deployment.sh" -ForegroundColor Yellow
        Write-Host "`n5. Run the deployment script:" -ForegroundColor White
        Write-Host "   ./start-deployment.sh" -ForegroundColor Yellow
        Write-Host "`nThe script will create all necessary networks, start containers, and connect them properly." -ForegroundColor White
        
        # Restart any containers that were stopped for zip creation
        if ($global:stoppedContainers -and $global:stoppedContainers.Count -gt 0) {
            Write-Host "Restarting containers that were stopped for zip creation..." -ForegroundColor Yellow
            foreach ($container in $global:stoppedContainers) {
                Write-Host "Starting container: $container" -ForegroundColor Yellow
                docker start $container
            }
            Write-Host "All containers restarted." -ForegroundColor Green
        }
        
        return $true
    }
    catch {
        Write-Host "Error creating deployment archive: $_" -ForegroundColor Red
        return $false
    }
}

# After starting containers, add the OpenEMR configuration prompt
# Check Environment parameter directly instead of relying on DevMode variable
Write-Host "Debug before DevMode check: Environment=$Environment, DevMode=$script:DevMode" -ForegroundColor Magenta
if ($Environment -eq "dev") {
    # First prompt for database fix
    $fixDatabase = Get-UserInput -Prompt "Would you like to fix OpenEMR encryption keys (needed if you see blank screen issues)? (y/n) " -ValidResponses @("y", "n") -DefaultResponse "n"
    if ($fixDatabase -eq "y") {
        Write-Host "Fixing OpenEMR database encryption keys..." -ForegroundColor Yellow
        Fix-OpenEMRDatabase -Environment $Environment -ProjectName $envConfig.ProjectName
    } else {
        Write-Host "Skipping encryption key fix" -ForegroundColor Yellow
    }
    # Separate prompt for OpenEMR configuration
    $configureOpenEMR = Get-UserInput -Prompt "Would you like to configure OpenEMR for development mode? (y/n) " -ValidResponses @("y", "n") -DefaultResponse "n"
    if ($configureOpenEMR -eq "y") {
        Write-Host "Configuring OpenEMR for development mode..." -ForegroundColor Yellow
        Configure-OpenEMR -Environment $Environment -ProjectName $envConfig.ProjectName
    } else {
        Write-Host "Skipping OpenEMR configuration" -ForegroundColor Yellow
    }
    # First prompt for database fix
    $fixDatabase = Get-UserInput -Prompt "Would you like to fix OpenEMR module installer issues? (y/n) " -ValidResponses @("y", "n") -DefaultResponse "n"
    if ($fixDatabase -eq "y") {
        Write-Host "Fixing OpenEMR module installer issues..." -ForegroundColor Yellow
        Fix-OpenEMRModuleInstallerIssues -ProjectName $envConfig.ProjectName
    } else {
        Write-Host "Skipping module installer issues fix" -ForegroundColor Yellow
    }
}

# Prompt for creating a deployment archive
# Set default response based on domain - default to 'y' for non-localhost domains, 'n' for localhost
$zipDefaultResponse = if ($DomainBase -ne "localhost") { "y" } else { "n" }
$createZip = Get-UserInput -Prompt "Would you like to create a zip archive of the deployment? (y/n)" -ValidResponses @("y", "n") -DefaultResponse $zipDefaultResponse
if ($createZip -eq "y") {
    Write-Host "Creating deployment archive..." -ForegroundColor Yellow
    $zipResult = Zip-Deployment -ProjectName $envConfig.ProjectName -Environment $Environment
    if ($zipResult) {
        # After successful zip, prompt for Oracle deployment
        $oracleDeploy = Get-UserInput -Prompt "Would you like to deploy this environment to Oracle Free Tier with WireGuard? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "n"
        if ($oracleDeploy -eq "y") {
            # Find the most recent zip file matching the pattern
            $zipPattern = "$($envConfig.ProjectName)-$Environment-*.zip"
            $zipFile = Get-ChildItem -Path $PSScriptRoot -Filter $zipPattern | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($zipFile) {
                $destDir = Join-Path $PSScriptRoot "infrastructure-oci\resources"
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                $destZip = Join-Path $destDir "docker-wireguard-openemr.zip"
                Copy-Item -Path $zipFile.FullName -Destination $destZip -Force
                Write-Host "Copied deployment zip to: $destZip" -ForegroundColor Green
                # Optional: Prompt to run terraform apply
                $runTerraform = Get-UserInput -Prompt "Would you like to run 'terraform apply' now? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "n"
                if ($runTerraform -eq "y") {
                    Push-Location (Join-Path $PSScriptRoot "infrastructure-oci")
                    terraform apply
                    Pop-Location
                } else {
                    Write-Host "To deploy, run 'terraform apply' in the infrastructure-oci directory." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Could not find the deployment zip file to copy for Oracle deployment." -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host "Skipping deployment archive creation" -ForegroundColor Yellow
}

# Prompt to merge OpenEMR into WireGuard/Unbound deployment zip
$mergeToWireguardZip = Get-UserInput -Prompt "Would you like to merge your OpenEMR deployment into the WireGuard/Unbound deployment zip for Oracle? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "n"
if ($mergeToWireguardZip -eq "y") {
    $wireguardZip = Join-Path $PSScriptRoot "infrastructure-oci\resources\docker-wireguard-unbound.zip"
    $tempDir = Join-Path $PSScriptRoot "temp-merge"
    $openemrDir = Join-Path $PSScriptRoot "$($envConfig.ProjectName)-$Environment"  # or however your output dir is named

    # 1. Extract the existing zip
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    Expand-Archive -Path $wireguardZip -DestinationPath $tempDir

    # 2. Copy OpenEMR deployment into the extracted directory
    Copy-Item -Path "$openemrDir\*" -Destination $tempDir -Recurse -Force

    # 2.5 Remove AdGuard service from docker-compose.yml if present
    $composePath = Join-Path $tempDir "docker-compose.yml"
    if (Test-Path $composePath) {
        $composeContent = Get-Content $composePath -Raw
        # Remove the adguard service block (simple regex for YAML)
        $composeContent = $composeContent -replace "(?ms)^\s*adguard:.*?(?=^\S|\z)", ""
        Set-Content -Path $composePath -Value $composeContent
        Write-Host "Removed AdGuard service from docker-compose.yml in temp directory." -ForegroundColor Green
    }

    # 3. Re-zip everything
    if (Test-Path $wireguardZip) { Remove-Item $wireguardZip -Force }
    Compress-Archive -Path "$tempDir\*" -DestinationPath $wireguardZip -Force

    # 4. Clean up
    Remove-Item $tempDir -Recurse -Force

    Write-Host "Merged OpenEMR deployment into docker-wireguard-unbound.zip" -ForegroundColor Green
}

Write-Host "Setup complete for $($envConfig.ProjectName)!" -ForegroundColor Green

# Check if Terraform is available in PATH, if not, download and extract the latest version
function Ensure-Terraform {
    $terraformCmd = "terraform"
    $terraformExe = "terraform.exe"
    $terraformExtractDir = Join-Path $PSScriptRoot "terraform-bin"
    $terraformPath = $null

    # Check if terraform is in PATH
    $found = $false
    $env:PATH.Split(';') | ForEach-Object {
        if (Test-Path (Join-Path $_ $terraformExe)) {
            $found = $true
            $terraformPath = Join-Path $_ $terraformExe
        }
    }

    if (-not $found) {
        Write-Host "Terraform not found in PATH. Downloading latest version..." -ForegroundColor Cyan
        # Get latest version from releases.hashicorp.com
        $releasesUrl = "https://releases.hashicorp.com/terraform/"
        $html = Invoke-WebRequest -Uri $releasesUrl -UseBasicParsing
        $version = ($html.Links | Where-Object { $_.href -match "^/terraform/1\\.[0-9]+\\.[0-9]+/?$" } | ForEach-Object { $_.href -replace "/terraform/|/$", "" } | Sort-Object -Descending | Select-Object -First 1)
        if (-not $version) { $version = "1.7.5" } # fallback
        $terraformZipUrl = "https://releases.hashicorp.com/terraform/$version/terraform_${version}_windows_amd64.zip"
        $terraformZipPath = Join-Path $PSScriptRoot "terraform_${version}_windows_amd64.zip"

        # Download
        Invoke-WebRequest -Uri $terraformZipUrl -OutFile $terraformZipPath
        if (-not (Test-Path $terraformExtractDir)) {
            New-Item -ItemType Directory -Path $terraformExtractDir | Out-Null
        }
        Expand-Archive -Path $terraformZipPath -DestinationPath $terraformExtractDir -Force
        Remove-Item $terraformZipPath -Force
        $terraformPath = Join-Path $terraformExtractDir $terraformExe
        $env:PATH = "$terraformExtractDir;$env:PATH"
        Write-Host "Terraform $version downloaded and available at $terraformPath" -ForegroundColor Green
    } else {
        Write-Host "Terraform found in PATH at $terraformPath" -ForegroundColor Green
    }
    return $terraformPath
}

# Ensure Terraform is available before any terraform commands
$TerraformExePath = Ensure-Terraform

# After copying/merging the deployment zip and before running terraform
$oracleDeploy = Get-UserInput -Prompt "Would you like to deploy this environment to Oracle Free Tier with WireGuard? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "n"
if ($oracleDeploy -eq "y") {
    # Ensure Terraform is available
    $TerraformExePath = Ensure-Terraform
    $infraDir = Join-Path $PSScriptRoot "infrastructure-oci"
    Push-Location $infraDir
    try {
        Write-Host "Running: terraform init" -ForegroundColor Cyan
        & $TerraformExePath init
        Write-Host "Running: terraform plan" -ForegroundColor Cyan
        & $TerraformExePath plan
        Write-Host "Running: terraform apply" -ForegroundColor Cyan
        & $TerraformExePath apply
    } catch {
        Write-Host "Error running Terraform: $_" -ForegroundColor Red
    } finally {
        Pop-Location
    }
}

# Check if we need to deploy to a remote server (non-localhost domain)
if ($DomainBase -ne "localhost") {
    Write-Host "\nNon-localhost domain detected: $DomainBase" -ForegroundColor Cyan
    $remoteDeployPrompt = "Would you like to deploy this environment to a remote server? (y/n)"
    $remoteDeployResponse = Get-UserInput -Prompt $remoteDeployPrompt -ValidResponses @("y", "n") -DefaultResponse "y"
    
    if ($remoteDeployResponse -eq "y") {
        Write-Host "Preparing for remote deployment..." -ForegroundColor Cyan
        
        # Create a deployment zip if it doesn't exist
        $deploymentZips = Get-ChildItem -Path $PSScriptRoot -Filter "$Project-$Environment-*.zip" | Sort-Object LastWriteTime -Descending
        
        if ($deploymentZips.Count -eq 0) {
            Write-Host "No deployment package found. Creating one now..." -ForegroundColor Yellow
            Zip-Deployment -ProjectName "$Project-$Environment" -Environment $Environment
            
            # Refresh the list of deployment zips
            $deploymentZips = Get-ChildItem -Path $PSScriptRoot -Filter "$Project-$Environment-*.zip" | Sort-Object LastWriteTime -Descending
            
            if ($deploymentZips.Count -eq 0) {
                Write-Host "Failed to create deployment package. Remote deployment cannot proceed." -ForegroundColor Red
                return
            }
        }
        
        # Get remote server details
        Write-Host "\nRemote Server Configuration:" -ForegroundColor Cyan
        $defaultRemoteServer = "129.158.220.120"
        $defaultRemoteUser = "ubuntu"
        $defaultKeyPath = "E:\Downloads\vr2fit_arm.ppk"
        
        $remoteServer = Get-UserInput -Prompt "Remote server IP address" -DefaultResponse $defaultRemoteServer
        $remoteUser = Get-UserInput -Prompt "Remote server username" -DefaultResponse $defaultRemoteUser
        $keyPath = Get-UserInput -Prompt "Path to SSH key file" -DefaultResponse $defaultKeyPath
        
        # Call deploy-remote.ps1 with the appropriate parameters
        Write-Host "\nStarting remote deployment..." -ForegroundColor Cyan
        $deployRemoteScript = Join-Path $PSScriptRoot "deploy-remote.ps1"
        
        if (Test-Path $deployRemoteScript) {
            & $deployRemoteScript -Environment $Environment -Project $Project -DomainBase $DomainBase -RemoteServer $remoteServer -RemoteUser $remoteUser -KeyPath $keyPath
        } else {
            Write-Host "Error: deploy-remote.ps1 script not found at $deployRemoteScript" -ForegroundColor Red
        }
    }
}

# Function to check if OpenEMR is ready by testing the API endpoint
function Test-OpenEMRReady {
    param (
        [string]$ContainerName = "official-${Environment}-openemr-1",
        [int]$TimeoutSeconds = 360,
        [int]$RetryIntervalSeconds = 10
    )
    
    Write-Host "Waiting for OpenEMR to be fully initialized..." -ForegroundColor Yellow
    
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)
    $ready = $false
    
    while ((Get-Date) -lt $endTime -and -not $ready) {
        try {
            # Check if container is running
            $containerStatus = docker ps --filter "name=$ContainerName" --format "{{.Status}}"
            
            if (-not $containerStatus) {
                Write-Host "OpenEMR container is not running yet. Waiting..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryIntervalSeconds
                continue
            }
            
            # Try to access the OpenEMR API endpoint
            $response = docker exec $ContainerName curl -s -o /dev/null -w "%{http_code}" http://localhost/openemr/apis/default/product
            
            # Consider both 200 and 404 as signals that OpenEMR is running
            # 404 means the application is responding but the endpoint doesn't exist
            # which is fine - we just need to know the web server is up
            if ($response -eq "200" -or $response -eq "404") {
                Write-Host "OpenEMR is ready! (Status code: $response)" -ForegroundColor Green
                $ready = $true
            } else {
                Write-Host "OpenEMR returned status code: $response. Waiting..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryIntervalSeconds
            }
        } catch {
            Write-Host "Error checking OpenEMR status: $_. Retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryIntervalSeconds
        }
    }
    
    if (-not $ready) {
        Write-Host "Timed out waiting for OpenEMR to initialize after $TimeoutSeconds seconds." -ForegroundColor Red
        return $false
    }
    
    return $true
}

# Deploy Telehealth Module at the end
if ($DomainBase -eq "localhost") {  # Only run for local deployments
    # Wait for OpenEMR to be fully initialized
    if (Test-OpenEMRReady) {
        Write-Host "\nDeploying Telehealth Module..." -ForegroundColor Cyan
        $deployTelehealthScript = Join-Path $PSScriptRoot "deploy-telehealth-module.ps1"
        
        if (Test-Path $deployTelehealthScript) {
            # Run with -Force to perform clean uninstall and installation
            # Include Project and Environment parameters when calling the script
            Write-Host "Running: $deployTelehealthScript -Force -Project $Project -Environment $Environment" -ForegroundColor Yellow
            & $deployTelehealthScript -Force -Project $Project -Environment $Environment
            Write-Host "Telehealth Module deployment completed." -ForegroundColor Green
        } else {
            Write-Host "Error: deploy-telehealth-module.ps1 script not found at $deployTelehealthScript" -ForegroundColor Red
        }
    } else {
        Write-Host "Skipping Telehealth Module deployment because OpenEMR is not ready." -ForegroundColor Yellow
    }
}