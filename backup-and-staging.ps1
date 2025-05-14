# All-In-One Telehealth Platform Environment Setup Script
# This script performs a complete backup and creates a new environment (staging, dev, or test)

param (
    [Parameter(Mandatory=$false)]
    [string]$Environment,
    [string]$Project = "aiotp",
    [switch]$StagingEnvironment = $false,  # Keep for backward compatibility
    [switch]$RunSetup = $true,  # Default to true to always run setup.ps1 after environment creation
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",  # Path to source repositories
    [switch]$ForceRebuildWorkingCopy = $false,  # Whether to force rebuild of working copies
    [string]$DomainBase = "localhost",  # Default domain base is "localhost"
    [switch]$Force, # Add the Force switch
    [switch]$SkipRepoUpdate, # Add switch to optionally skip repo updates
    [switch]$ARM # Add ARM switch for ARM architecture
)

# Function to get user input with clear prompting
function Get-UserInput {
    param (
        [string]$Prompt,
        [string]$ForegroundColor = "Yellow",
        [string[]]$ValidResponses = @(),
        [string]$DefaultResponse = ""
    )
    
    # If Force switch is used, return default without prompting
    if ($Force) {
        Write-Host "$Prompt [$DefaultResponse] (Auto-selected due to -Force flag)" -ForegroundColor $ForegroundColor
        return $DefaultResponse
    }
    
    # Otherwise, always prompt
    Write-Host $Prompt -ForegroundColor $ForegroundColor -NoNewline
    $input = Read-Host
    
    # Use default if input is empty
    if ([string]::IsNullOrEmpty($input) -and -not [string]::IsNullOrEmpty($DefaultResponse)) {
        return $DefaultResponse
    }
    
    # Validate input if validation is required
    if ($ValidResponses.Count -gt 0) {
        while ($ValidResponses -notcontains $input.ToLower()) {
            Write-Host "Invalid input. Please enter one of: $($ValidResponses -join ', ')" -ForegroundColor Red
            Write-Host $Prompt -ForegroundColor $ForegroundColor -NoNewline
            $input = Read-Host
        }
    }
    
    return $input
}

# If no environment is specified, show interactive selection
if (-not $Environment) {
    Write-Host "`nAvailable Environments:" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    
    # Load environment config to get available environments
    $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment "production" -Project $Project -DomainBase $DomainBase
    $availableEnvs = @('dev', 'staging', 'test', 'production')
    
    # Display numbered list of environments
    for ($i = 0; $i -lt $availableEnvs.Count; $i++) {
        Write-Host "$($i + 1). $($availableEnvs[$i])" -ForegroundColor Yellow
    }
    
    # Get user selection
    while ($true) {
        $selection = Read-Host "`nSelect environment number (1-$($availableEnvs.Count))"
        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $availableEnvs.Count) {
            $Environment = $availableEnvs[[int]$selection - 1]
            break
        }
        Write-Host "Invalid selection. Please enter a number between 1 and $($availableEnvs.Count)" -ForegroundColor Red
    }
    
    Write-Host "`nSelected environment: $Environment" -ForegroundColor Green
    
    # Prompt for project selection
    Write-Host "`nAvailable Projects:" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan
    Write-Host "1. aiotp (Default project)" -ForegroundColor Yellow
    Write-Host "2. jmdurant (JM Durant's fork)" -ForegroundColor Yellow
    Write-Host "3. official (Official OpenEMR)" -ForegroundColor Yellow
    
    # Get user project selection
    while ($true) {
        $projectSelection = Read-Host "`nSelect project number (1-3) or press Enter for default (aiotp)"
        if ([string]::IsNullOrEmpty($projectSelection)) {
            $Project = "aiotp"
            break
        }
        
        if ($projectSelection -match '^\d+$' -and [int]$projectSelection -ge 1 -and [int]$projectSelection -le 3) {
            $Project = switch ([int]$projectSelection) {
                1 { "aiotp" }
                2 { "jmdurant" }
                3 { "official" }
                default { "aiotp" }
            }
            break
        }
        
        Write-Host "Invalid selection. Please enter a number between 1 and 3" -ForegroundColor Red
    }
    
    Write-Host "`nSelected project: $Project" -ForegroundColor Green
    
    # Ask user if they want to change the domain base
    $changeDomain = Get-UserInput "`nWould you like to use a custom domain base instead of 'localhost'? (y/n) " -ValidResponses @("y", "n") -DefaultResponse "n"
    
    if ($changeDomain -eq "y") {
        $DomainBase = Read-Host "Enter the domain base you want to use (e.g., example.com)"
        if ([string]::IsNullOrEmpty($DomainBase)) {
            $DomainBase = "localhost"
            Write-Host "Using default domain base: $DomainBase" -ForegroundColor Yellow
        } else {
            Write-Host "Using custom domain base: $DomainBase" -ForegroundColor Green
        }
    } else {
        Write-Host "Using default domain base: $DomainBase" -ForegroundColor Yellow
    }
    
    # Prompt for ARM architecture
    $useARM = Get-UserInput "`nDo you want to use ARM architecture? (y/n) " -ValidResponses @("y", "n") -DefaultResponse "n"
    if ($useARM -eq "y") {
        $ARM = $true
        Write-Host "Using ARM architecture" -ForegroundColor Green
    } else {
        $ARM = $false
        Write-Host "Using standard architecture" -ForegroundColor Green
    }
}

# Handle backward compatibility with -StagingEnvironment switch
if ($StagingEnvironment) {
    $Environment = "staging"
}

# Validate environment parameter
if ([string]::IsNullOrEmpty($Environment)) {
    Write-ErrorAndExit "Environment parameter is required. Valid values: staging, dev, test"
}

# Set DevMode based on environment (true for dev, false otherwise)
$script:DevMode = $Environment -eq "dev"
Write-Host "DevMode is $(if ($script:DevMode) { "enabled" } else { "disabled" }) for $Environment environment" -ForegroundColor $(if ($script:DevMode) { "Green" } else { "Yellow" })

# Source repository variables
$sourceDir = "$PSScriptRoot\source-repos"
# Determine source directories based on project - adjust these base names as needed
$openemrSourceDirBase = switch ($Project) {
    'jmdurant' { "openemr-telesalud" }
    'official' { "openemr" }
    default    { "openemr-telesalud" } # Default to aiotp's repo name
}
$openemrSourceDir = Join-Path -Path $sourceDir -ChildPath $openemrSourceDirBase
$telehealthSourceDir = Join-Path -Path $sourceDir -ChildPath "ciips-telesalud"

# Update source repositories unless skipped
if (-not $SkipRepoUpdate) {
    Write-Host "Updating source repositories (use -SkipRepoUpdate to disable)..." -ForegroundColor Yellow
    # Define repo URLs and branches based on the project
    $OpenEMRRepoUrl = switch ($Project) {
        'jmdurant' { "https://github.com/jmdurant/openemr-aio.git" } # Corrected URL
        'official' { "https://github.com/openemr/openemr.git" }
        default    { "https://github.com/ciips-ops/openemr-telesalud.git" } # Default to aiotp's fork
    }
    $TelehealthRepoUrl = "https://github.com/ciips-code/ciips-telesalud.git" # Corrected URL
    # Define branches dynamically based on project
    $OpenEMRBranch = switch ($Project) {
        'official' { "master" } # Official repo uses master
        'jmdurant' { "master" } # Corrected: Assume jmdurant fork also uses master
        default    { "main" }   # Assuming aiotp fork uses main
    }
    $TelehealthBranch = "master" # Corrected: Telehealth repo uses master

    Write-Host "Using OpenEMR branch: $OpenEMRBranch" -ForegroundColor Cyan
    Write-Host "Using Telehealth branch: $TelehealthBranch" -ForegroundColor Cyan

    # Call the update script with correct branch names and environment parameter
    $repoResult = . "$PSScriptRoot\update-source-repos.ps1" -Project $Project -Environment $Environment -DomainBase $DomainBase -OpenEMRRepoUrl $OpenEMRRepoUrl -TelehealthRepoUrl $TelehealthRepoUrl -OpenEMRBranch $OpenEMRBranch -TelehealthBranch $TelehealthBranch -Force:$Force
    
    # Add debug output to verify environment parameter
    Write-Host "Debug: Called update-source-repos.ps1 with Environment=$Environment" -ForegroundColor Magenta
    
    if (-not $repoResult.Success) {
        Write-Host "Failed to update source repositories. Continuing with existing repositories if they exist..." -ForegroundColor Yellow
    }
    
    # Update source dir paths based on script result (it might adjust for 'official')
    $openemrSourceDir = $repoResult.OpenEMRSourceDir
    $telehealthSourceDir = $repoResult.TelehealthSourceDir
} else {
    Write-Host "Skipping source repository update due to -SkipRepoUpdate flag." -ForegroundColor Yellow
    # Check if required source directories exist if skipping update
    if (-not (Test-Path $openemrSourceDir) -or ($Project -ne 'official' -and -not (Test-Path $telehealthSourceDir))) {
        Write-Host "Source repository directory ($openemrSourceDir or $telehealthSourceDir) not found and update was skipped. This may cause errors." -ForegroundColor Red
        # Consider exiting here or providing a stronger warning
    }
}

# Special handling for "official" project remains (ensure directory exists)
if ($Project -eq "official") {
    Write-Host "Using official OpenEMR source directory: $openemrSourceDir" -ForegroundColor Green
    # Make sure the right repository is available, attempt clone if missing AND update wasn't skipped
    if ((-not (Test-Path $openemrSourceDir)) -and (-not $SkipRepoUpdate)) {
        Write-Host "Official OpenEMR source repository not found. Attempting to clone it now..." -ForegroundColor Yellow
        # Call update script specifically for official project
        $repoResult = . "$PSScriptRoot\update-source-repos.ps1" -Project "official" -DomainBase $DomainBase -Force:$Force
        
        if (-not $repoResult.Success) {
            Write-ErrorAndExit "Failed to clone official OpenEMR repository. Please clone it manually to $openemrSourceDir or run without -SkipRepoUpdate."
        }
        $openemrSourceDir = $repoResult.OpenEMRSourceDir
    } elseif (-not (Test-Path $openemrSourceDir)) {
         Write-ErrorAndExit "Official OpenEMR source repository ($openemrSourceDir) not found and update was skipped. Cannot proceed."
    }
}

# Error handling function
function Write-ErrorAndExit {
    param (
        [string]$Message,
        [int]$ExitCode = 1
    )
    
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $ExitCode
}

# Function to ensure shared Jitsi instance is running
function Ensure-SharedJitsi {
    Write-Host "Checking shared Jitsi instance..." -ForegroundColor Yellow
    
    $jitsiDir = "$PSScriptRoot\shared\jitsi-docker"
    if (-not (Test-Path $jitsiDir)) {
        Write-Host "Shared Jitsi directory not found. Creating..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $jitsiDir -Force | Out-Null
    }
    
    # Check if Jitsi is running
    $jitsiRunning = docker ps -q --filter "name=jitsi" | Measure-Object | Select-Object -ExpandProperty Count -gt 0
    if (-not $jitsiRunning) {
        Write-Host "Starting shared Jitsi instance..." -ForegroundColor Yellow
        Set-Location -Path $jitsiDir
        docker-compose up -d
        Set-Location -Path $PSScriptRoot
    } else {
        Write-Host "Shared Jitsi instance is already running" -ForegroundColor Green
    }
}

# Function to update docker-compose files
function Update-DockerComposeFile {
    param (
        [string]$FilePath,
        [string]$Component
    )
    
    try {
        # Read the original docker-compose file
        $content = Get-Content -Path $FilePath -Raw
        
        # Remove version attribute and container_name directives
        $content = $content -replace "version: '.*?'`r?`n", ""
        $content = $content -replace "container_name:.*`r?`n", ""
        
        # Save the updated content back to the file
        Set-Content -Path $FilePath -Value $content
        Write-Host "Updated docker-compose file at: $FilePath" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Error updating docker-compose file: $_" -ForegroundColor Red
        return $false
    }
}

# Function to create environment variable files
function Create-EnvironmentVariableFile {
    param (
        [string]$TargetDir,
        [string]$Component
    )
    
    try {
        $envContent = @"
# Environment variables for $Component in $Environment environment
# Generated: $(Get-Date)
COMPOSE_PROJECT_NAME=$($envConfig.ProjectName)-$Component
FRONTEND_NETWORK=$($envConfig.FrontendNetwork)
PROXY_NETWORK=$($envConfig.ProxyNetwork)
"@
        
        if ($Component -eq "openemr") {
            $envContent += @"

# OpenEMR specific variables
HTTP_PORT=$($envConfig.Config.containerPorts.openemr.http)
HTTPS_PORT=$($envConfig.Config.containerPorts.openemr.https)
DOMAIN=$($envConfig.Domains.openemr)
"@
        } elseif ($Component -eq "telehealth") {
            $envContent += @"

# Telehealth specific variables
APP_PORT=$($envConfig.Config.containerPorts.telehealth.app)
WEB_PORT=$($envConfig.Config.containerPorts.telehealth.web)
DB_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.db)
DOMAIN=$($envConfig.Domains.telehealth)

# Database configuration
DB_HOST=database
DB_PORT=$($envConfig.Config.containerPorts.telehealth.db_port)
DB_DATABASE=telehealth
DB_USERNAME=telehealth
DB_PASSWORD=telehealth_password

# JWT configuration for shared Jitsi
JWT_APP_ID=telehealth
JWT_APP_SECRET=OafDjrVt8r
JWT_ISSUER=$Environment
"@
        } elseif ($Component -eq "proxy") {
            $envContent += @"

# Nginx Proxy Manager specific variables
HTTP_PORT=$($envConfig.Config.npmPorts.http)
HTTPS_PORT=$($envConfig.Config.npmPorts.https)
ADMIN_PORT=$($envConfig.Config.npmPorts.admin)
"@
        }
        
        Set-Content -Path "$TargetDir\.env" -Value $envContent -Force -ErrorAction Stop
        Write-Host "Created .env file for $Component" -ForegroundColor Green
    } catch {
        Write-Host "Error creating .env file for $Component$([char]58) $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Function to create start script
function Create-StartScript {
    try {
        $startupScriptContent = @"
# Environment Startup Script for $Environment
# Generated: $(Get-Date)

# Set working directory to the script location
Push-Location -Path `$PSScriptRoot

# Ensure networks exist
. "`$PSScriptRoot\..\network-setup.ps1" -Environment $Environment -Project $Project -DomainBase "$DomainBase"

# Ensure shared Jitsi instance is running
. "`$PSScriptRoot\..\shared\jitsi-docker\start-jitsi.ps1"

# Start components in the correct order
Write-Host "Starting $Environment environment..." -ForegroundColor Yellow

# Start Proxy
Write-Host "Starting Proxy..." -ForegroundColor Yellow
Set-Location -Path "$($envConfig.FolderNames.proxy)"
docker-compose up -d
Set-Location -Path `$PSScriptRoot
"@
        
        Set-Content -Path "$targetDir\start-$Environment.ps1" -Value $startupScriptContent -Force -ErrorAction Stop
        Write-Host "Created startup script for $Environment" -ForegroundColor Green
    } catch {
        Write-Host "Error creating startup script: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Function to create stop script
function Create-StopScript {
    try {
        $shutdownScriptContent = @"
# Environment Shutdown Script for $Environment
# Generated: $(Get-Date)

# Set working directory to the script location
Push-Location -Path `$PSScriptRoot

# Ensure we're using the correct project names
\$baseProjectName = "$($envConfig.ProjectName)"
\$openemrProject = "\$baseProjectName-$($envConfig.FolderNames.openemr)"
\$telehealthProject = "\$baseProjectName-$($envConfig.FolderNames.telehealth)"
\$jitsiProject = "\$baseProjectName-$($envConfig.FolderNames.jitsi)"
\$proxyProject = "\$baseProjectName-$($envConfig.FolderNames.proxy)"

Write-Host "Stopping $Environment environment..." -ForegroundColor Yellow

# Stop Jitsi
Write-Host "Stopping Jitsi..." -ForegroundColor Yellow
Set-Location -Path "$($envConfig.FolderNames.jitsi)"
docker-compose down
Set-Location -Path `$PSScriptRoot

# Stop Telehealth
Write-Host "Stopping Telehealth..." -ForegroundColor Yellow
Set-Location -Path "$($envConfig.FolderNames.telehealth)"
docker-compose down
Set-Location -Path `$PSScriptRoot

# Stop OpenEMR
Write-Host "Stopping OpenEMR..." -ForegroundColor Yellow
Set-Location -Path "$($envConfig.FolderNames.openemr)"
docker-compose down
Set-Location -Path `$PSScriptRoot

# Stop Proxy
Write-Host "Stopping Proxy..." -ForegroundColor Yellow
Set-Location -Path "$($envConfig.FolderNames.proxy)"
docker-compose down
Set-Location -Path `$PSScriptRoot

# Restore original location
Pop-Location

Write-Host "$Environment environment stopped successfully!" -ForegroundColor Green
"@
        Set-Content -Path "$targetDir\stop-$Environment.ps1" -Value $shutdownScriptContent -Force -ErrorAction Stop
        Write-Host "Created stop script: $targetDir\stop-$Environment.ps1" -ForegroundColor Green
    } catch {
        Write-Host "Error creating stop script$([char]58) $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Function to find the appropriate docker-compose file based on environment
function Get-EnvironmentDockerComposeFile {
    param (
        [string]$SourceDir,
        [string]$Environment,
        [string]$ComponentName
    )
    
    # Define possible file paths in order of preference
    $possibleFiles = @()
    
    # Special case for OpenEMR which has a different structure
    if ($ComponentName -eq "OpenEMR") {
        # According to deployment instructions, OpenEMR files are in ciips/docker directory
        # First check for exact environment match
        $possibleFiles += "$SourceDir\ciips\docker\docker-compose.$Environment.yml"
        
        # For non-prod environments, prefer dev configuration
        if ($Environment -ne "prod" -and $Environment -ne "production") {
            $possibleFiles += "$SourceDir\ciips\docker\docker-compose.dev.yml"
        }
        
        # For prod environment, use prod configuration
        if ($Environment -eq "prod" -or $Environment -eq "production") {
            $possibleFiles += "$SourceDir\ciips\docker\docker-compose.prod.yml"
        }
        
        # Last resort - check for default docker-compose.yml
        $possibleFiles += "$SourceDir\ciips\docker\docker-compose.yml"
        
        # Legacy paths as fallback
        $possibleFiles += @(
            "$SourceDir\docker\production\docker-compose.yml",
            "$SourceDir\docker\docker-compose.yml"
        )
    } else {
        # First check for exact environment match
        $possibleFiles += "$SourceDir\docker-compose.$Environment.yml"
        
        # For non-prod environments, prefer dev configuration
        if ($Environment -ne "prod" -and $Environment -ne "production") {
            $possibleFiles += "$SourceDir\docker-compose.dev.yml"
        }
        
        # For prod environment, use prod configuration
        if ($Environment -eq "prod" -or $Environment -eq "production") {
            $possibleFiles += "$SourceDir\docker-compose.prod.yml"
        }
        
        # Last resort - check for default docker-compose.yml
        $possibleFiles += "$SourceDir\docker-compose.yml"
    }
    
    # Return the first file that exists
    foreach ($file in $possibleFiles) {
        if (Test-Path $file) {
            Write-Host "Found $ComponentName docker-compose file: $file" -ForegroundColor Green
            return $file
        }
    }
    
    # If no file is found, return null
    Write-Host "No suitable docker-compose file found for $ComponentName in $SourceDir" -ForegroundColor Yellow
    return $null
}

# Function to copy Docker Compose files from source repository
function Copy-DockerComposeFromSource {
    param (
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$ComponentName
    )
    
    if (-not (Test-Path $SourcePath)) {
        Write-Host "$ComponentName docker-compose file not found at: $SourcePath" -ForegroundColor Yellow
        return $false
    }
    
    try {
        Copy-Item -Path $SourcePath -Destination $TargetPath -Force -ErrorAction Stop
        Write-Host "Copied $ComponentName docker-compose.yml from source repository" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Error copying $ComponentName docker-compose.yml: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Function to handle OpenEMR .env file
function Copy-OpenEMREnvFile {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment
    )
    
    # Determine the appropriate .env.example location based on project type
    $envExamplePath = if ($Project -eq "official") {
        # For official OpenEMR, look in the root directory
        "$SourceDir\.env.example"
    } else {
        # For custom OpenEMR, look in the ciips/docker directory
        "$SourceDir\ciips\docker\.env.example"
    }
    $envTargetPath = "$TargetDir\.env"
    
    Write-Host "Looking for OpenEMR .env.example file at: $envExamplePath" -ForegroundColor Yellow
    
    if (Test-Path $envExamplePath) {
        Write-Host "Found OpenEMR .env.example file at: $envExamplePath" -ForegroundColor Green
        
        try {
            # Read the .env.example file content
            $envContent = Get-Content -Path $envExamplePath -Raw
            
            # Add timestamp and environment information
            $timestamp = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
            $envContent = "# Environment variables for openemr in $Environment environment`n# Generated: $timestamp`n$envContent"
            
            # Ensure all required variables are set (not commented)
            # First, uncomment all commented variables that we need
            $envContent = $envContent -replace "COMPOSE_PROJECT_NAME=.*", "COMPOSE_PROJECT_NAME=$Project-$Environment-openemr"
            $envContent = $envContent -replace "#MYSQL_ROOT_PASSWORD=.*", "MYSQL_ROOT_PASSWORD=root"
            $envContent = $envContent -replace "#MYSQL_DATABASE=.*", "MYSQL_DATABASE=openemr"
            $envContent = $envContent -replace "#MYSQL_USER=.*", "MYSQL_USER=openemr"
            $envContent = $envContent -replace "#MYSQL_PASSWORD=.*", "MYSQL_PASSWORD=openemr"
            $envContent = $envContent -replace "MYSQL_PORT=.*", "MYSQL_PORT=3306"
            $envContent = $envContent -replace "OPENEMR_PORT=.*", "OPENEMR_PORT=$($envConfig.Config.containerPorts.openemr.http)"
            $envContent = $envContent -replace "TELEHEALTH_PORT=.*", "TELEHEALTH_PORT=$($envConfig.Config.containerPorts.openemr.telehealth_port)"
            $envContent = $envContent -replace "TELEHEALTH_BASE_URL=.*", "TELEHEALTH_BASE_URL=https://$($envConfig.Domains.telehealth)"

            
            # Add environment-specific network settings
            if (-not ($envContent -match "FRONTEND_NETWORK=")) {
                $envContent += "`nFRONTEND_NETWORK=frontend-$Environment`n"
            } else {
                $envContent = $envContent -replace "FRONTEND_NETWORK=.*", "FRONTEND_NETWORK=frontend-$Environment"
            }
            
            if (-not ($envContent -match "PROXY_NETWORK=")) {
                $envContent += "`nPROXY_NETWORK=proxy-$Environment`n"
            } else {
                $envContent = $envContent -replace "PROXY_NETWORK=.*", "PROXY_NETWORK=proxy-$Environment"
            }
            
            # Add domain setting if not present
            if (-not ($envContent -match "DOMAIN=")) {
                $envContent += "`nDOMAIN=$($envConfig.Domains.openemr)`n"
            } else {
                $envContent = $envContent -replace "DOMAIN=.*", "DOMAIN=$($envConfig.Domains.openemr)"
            }
            
            # Uncomment and set NGINX_UID for dev environment and uncomment other settings
            if ($DevMode -eq $true) {
                Write-Host "Dev Mode detected, setting NGINX_UID and OPENEMR_SITE_VOLUME for development" -ForegroundColor Green
                $envContent = $envContent -replace "#NGINX_UID=.*", "NGINX_UID=1000"
                
                # Set OPENEMR_SITE_VOLUME
                $openemrSourceDir = "$SourceDir"
                if ($openemrSourceDir -match "\\") {
                    # Convert Windows path to proper format for Docker
                    $openemrSourceDir = $openemrSourceDir -replace "\\", "/"
                }
                
                # Try multiple patterns to ensure we catch the OPENEMR_SITE_VOLUME line
                if ($envContent -match "#OPENEMR_SITE_VOLUME=") {
                    $envContent = $envContent -replace "#OPENEMR_SITE_VOLUME=.*", "OPENEMR_SITE_VOLUME=$TargetDir"
                } elseif ($envContent -match "OPENEMR_SITE_VOLUME=") {
                    $envContent = $envContent -replace "OPENEMR_SITE_VOLUME=.*", "OPENEMR_SITE_VOLUME=$TargetDir"
                } else {
                    # If no pattern matches, add the line
                    $envContent += "`nOPENEMR_SITE_VOLUME=$TargetDir`n"
                }
                # Create sqlconf.php from the sample file
                
            } else {
                # For non-dev mode, still set OPENEMR_SITE_VOLUME to a named volume
                $envContent = $envContent -replace "#OPENEMR_SITE_VOLUME=.*", "OPENEMR_SITE_VOLUME=$Project-$Environment-openemr-site-volume"
                $envContent = $envContent -replace "OPENEMR_SITE_VOLUME=.*", "OPENEMR_SITE_VOLUME=$Project-$Environment-openemr-site-volume"
            }
            
            # Write the updated content to the target file
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Created/Updated .env file at: $envTargetPath" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Error creating .env file: $_" -ForegroundColor Red
            return $false
        }
    }
    else {
        # If .env.example was not found in the expected location, try alternative locations as fallback
        $alternativePaths = @(
            "$SourceDir\.env.example",
            "$SourceDir\docker\.env.example",
            "$SourceDir\ciips\docker\.env.example"
        )
        
        # Remove the already-checked path from the alternatives
        $alternativePaths = $alternativePaths | Where-Object { $_ -ne $envExamplePath }
        
        # Try each alternative path
        foreach ($altPath in $alternativePaths) {
            Write-Host "Trying alternative location: $altPath" -ForegroundColor Yellow
            if (Test-Path $altPath) {
                Write-Host "Found OpenEMR .env.example at alternative location: $altPath" -ForegroundColor Green
                # Set the found path as the new envExamplePath and call the function again
                $envExamplePath = $altPath
                return (Copy-OpenEMREnvFile -SourceDir $SourceDir -TargetDir $TargetDir -Environment $Environment)
            }
        }
        
        Write-Host "OpenEMR .env.example file not found in any expected location. Creating a basic one..." -ForegroundColor Yellow
        
        # Create a basic .env file if .env.example doesn't exist (especially important for official project)
        try {
            $timestamp = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
            $envContent = @"
# Environment file for $Project OpenEMR - $Environment
# Generated: $timestamp

COMPOSE_PROJECT_NAME=$Project-$Environment
HTTP_PORT=$($envConfig.Config.containerPorts.openemr.http)
HTTPS_PORT=$($envConfig.Config.containerPorts.openemr.https)
DOMAIN=$($envConfig.Domains.openemr)
FRONTEND_NETWORK=$($envConfig.FrontendNetwork)
PROXY_NETWORK=$($envConfig.ProxyNetwork)
"@
            
            # Write the content to the target file
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Created basic OpenEMR .env file at: $envTargetPath" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Error creating basic OpenEMR .env file: $_" -ForegroundColor Red
            return $false
        }
    }
}

# Function to handle Telehealth .env file
function Copy-TelehealthEnvFile {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment
    )
    
    # Check for .env.example in the source directory
    $envExamplePath = "$SourceDir\.env.example"
    $envTargetPath = "$TargetDir\.env"
    
    if (Test-Path $envExamplePath) {
        Write-Host "Found Telehealth .env.example file at: $envExamplePath" -ForegroundColor Yellow
        
        try {
            # Read the .env.example file content
            $envContent = Get-Content -Path $envExamplePath -Raw
            
            # Add timestamp and environment information
            $timestamp = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
            $envContent = "# Environment variables for telehealth in $Environment environment`n# Generated: $timestamp`n$envContent"
            
            # Map our environment variables to Telehealth's expected variables
            $envContent = $envContent -replace "WEB_LISTEN_PORT=.*", "WEB_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.web)"
            $envContent = $envContent -replace "WEB_HTTPS_LISTEN_PORT=.*", "WEB_HTTPS_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.https)"
            $envContent = $envContent -replace "DB_LISTEN_PORT=.*", "DB_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.db)"
            
            # Set environment-specific values
            $envContent = "COMPOSE_PROJECT_NAME=$Project-$Environment-telehealth`n$envContent"
            $envContent = $envContent -replace "COMPOSE_PROJECT_NAME=.*", "COMPOSE_PROJECT_NAME=$Project-$Environment-telehealth"
            $envContent = $envContent -replace "APP_ENV=.*", "APP_ENV=$Environment"
            $envContent = $envContent -replace "APP_URL=.*", "APP_URL=https://$($envConfig.Domains.telehealth)"
            
            # Database configuration
            $envContent = $envContent -replace "DB_HOST=.*", "DB_HOST=database"
            #$envContent = $envContent -replace "DB_PORT=.*", "DB_PORT=$($envConfig.Config.containerPorts.telehealth.db_port)"
            $envContent = $envContent -replace "DB_PORT=.*", "DB_PORT=3306"
            $envContent = $envContent -replace "DB_DATABASE=.*", "DB_DATABASE=telehealth"
            $envContent = $envContent -replace "DB_USERNAME=.*", "DB_USERNAME=telehealth"
            $envContent = $envContent -replace "DB_PASSWORD=.*", "DB_PASSWORD=telehealth_password"
            $envContent = $envContent -replace "NOTIFICATION_URL=.*", "NOTIFICATION_URL=https://openemr-telehealth.free.beeceptor.com/notifications"
            $envContent = $envContent -replace "LANGUAGE=.*", "LANGUAGE=en"
            $envContent = $envContent -replace "TIMEZONE=.*", "TIMEZONE=America/New_York"

            #Pusher Configuration
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_APP_ID=.*", "PUSHER_APP_ID=1965510"
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_APP_KEY=.*", "PUSHER_APP_KEY=1f66c6128c36dfb3d9bc"
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_APP_SECRET=.*", "PUSHER_APP_SECRET=5b86e50b293b136fb38f"
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_APP_CLUSTER=.*", "PUSHER_APP_CLUSTER=mt1"
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_HOST=.*", "PUSHER_HOST=https://api.pusherapp.com"
            $envContent = $envContent -replace "(?<!VITE_)PUSHER_APP_PORT=.*", "PUSHER_APP_PORT=443"

            # Jitsi configuration
            $envContent = $envContent -replace "JITSI_PROVIDER=.*", "JITSI_PROVIDER=self"
            $envContent = $envContent -replace "JITSI_BASE_URL=.*", "JITSI_BASE_URL=https://$($envConfig.Domains.jitsi)/"
            $envContent = $envContent -replace "JITSI_APP_ID=.*", "JITSI_APP_ID=telehealth"
            $envContent = $envContent -replace "JITSI_APP_SECRET=.*", "JITSI_APP_SECRET=OafDjrVt8r"
            
            # Uncomment WWW_DATA_UID for dev environment
            if ($Environment -eq "dev") {
                $envContent = $envContent -replace "#WWW_DATA_UID=.*", "WWW_DATA_UID=1000"
            }
            
            # Write the updated content to the target file
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Created/Updated .env file at: $envTargetPath" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Error creating Telehealth .env file: $_" -ForegroundColor Red
            return $false
        }
    }
    else {
        Write-Host "Telehealth .env.example file not found at: $envExamplePath" -ForegroundColor Yellow
        
        # Create a basic .env file if .env.example doesn't exist
        try {
            $envContent = @"
# Basic Telehealth .env file for $Environment environment
# Generated: $timestamp

# Port configuration
WEB_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.web)
WEB_HTTPS_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.https)
DB_LISTEN_PORT=$($envConfig.Config.containerPorts.telehealth.db)

# Application settings
APP_NAME=OS-Telesalud
APP_ENV=$Environment
APP_DEBUG=false
APP_URL=https://$($envConfig.Domains.telehealth)

# Database configuration
DB_CONNECTION=mysql
DB_HOST=database
DB_PORT=$($envConfig.Config.containerPorts.telehealth.db_port)
DB_DATABASE=telehealth
DB_USERNAME=telehealth
DB_PASSWORD=telehealth_password

# Jitsi configuration
JITSI_PROVIDER=self
JITSI_BASE_URL=https://$($envConfig.Domains.jitsi)/
JITSI_APP_ID=telehealth
JITSI_APP_SECRET=OafDjrVt8r

# Other settings
LANGUAGE=en
TIMEZONE=America/New_York
LOG_CHANNEL=stack
LOG_LEVEL=debug

# Queue and session settings
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120
"@
            
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Created basic .env file at: $envTargetPath" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Error creating basic Telehealth .env file: $_" -ForegroundColor Red
            return $false
        }
    }
}

# Function to handle Jitsi .env file
function Copy-JitsiEnvFile {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment,
        [string]$TelehealthDir
    )
    
    # Check for .env.example in jitsi-docker directory
    $envExamplePath = "$SourceDir\.env.example"
    $envTargetPath = "$TargetDir\.env"
    
    if (Test-Path $envExamplePath) {
        Write-Host "Found Jitsi .env.example file at: $envExamplePath" -ForegroundColor Yellow
        
        try {
            # Copy the .env.example file to .env
            Copy-Item -Path $envExamplePath -Destination $envTargetPath -Force
            Write-Host "Copied Jitsi .env.example to .env" -ForegroundColor Green
            
            # Read the .env file content
            $envContent = Get-Content -Path $envTargetPath -Raw
            
            # Add timestamp and environment information
            $timestamp = Get-Date -Format "MM/dd/yyyy HH:mm:ss"
            $envContent = "# Environment variables for Jitsi in $Environment environment`n# Generated: $timestamp`n$envContent"
            
            # Update environment-specific settings
            $envContent = $envContent -replace "COMPOSE_PROJECT_NAME=.*", "COMPOSE_PROJECT_NAME=$Project-jitsi"
            $envContent = $envContent -replace "HTTP_PORT=.*", "HTTP_PORT=$($envConfig.Config.containerPorts.jitsi.http)"
            $envContent = $envContent -replace "HTTPS_PORT=.*", "HTTPS_PORT=$($envConfig.Config.containerPorts.jitsi.https)"
            $envContent = $envContent -replace "TZ=.*", "TZ=America/New_York"
            
            # Set the public URL
            $envContent = $envContent -replace "PUBLIC_URL=https://meet.example.com", "PUBLIC_URL=https://$($envConfig.Domains.jitsi)"
            
            # Enable authentication
            $envContent = $envContent -replace "#ENABLE_AUTH=1", "ENABLE_AUTH=1"
            $envContent = $envContent -replace "#AUTH_TYPE=jwt", "AUTH_TYPE=jwt"
            
            # Add network configuration
            if (-not ($envContent -match "FRONTEND_NETWORK=")) {
                $envContent += "`n# Network configuration"
                $envContent += "`nFRONTEND_NETWORK=$($envConfig.FrontendNetwork)"
                $envContent += "`nPROXY_NETWORK=$($envConfig.ProxyNetwork)"
                $envContent += "`nDEFAULT_NETWORK=$Project-jitsi-default"
            } else {
                $envContent = $envContent -replace "FRONTEND_NETWORK=.*", "FRONTEND_NETWORK=$($envConfig.FrontendNetwork)"
                $envContent = $envContent -replace "PROXY_NETWORK=.*", "PROXY_NETWORK=$($envConfig.ProxyNetwork)"
            }
            
            # Generate random passwords for XMPP components if they don't exist
            if (-not ($envContent -match "JICOFO_AUTH_PASSWORD=.*[a-zA-Z0-9]")) {
                $jicofoPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
                $envContent = $envContent -replace "JICOFO_AUTH_PASSWORD=", "JICOFO_AUTH_PASSWORD=$jicofoPassword"
            }
            
            if (-not ($envContent -match "JVB_AUTH_PASSWORD=.*[a-zA-Z0-9]")) {
                $jvbPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
                $envContent = $envContent -replace "JVB_AUTH_PASSWORD=", "JVB_AUTH_PASSWORD=$jvbPassword"
            }
            
            if (-not ($envContent -match "JIGASI_XMPP_PASSWORD=.*[a-zA-Z0-9]")) {
                $jigasiPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
                $envContent = $envContent -replace "JIGASI_XMPP_PASSWORD=", "JIGASI_XMPP_PASSWORD=$jigasiPassword"
            }
            
            if (-not ($envContent -match "JIBRI_RECORDER_PASSWORD=.*[a-zA-Z0-9]")) {
                $jibriRecorderPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
                $envContent = $envContent -replace "JIBRI_RECORDER_PASSWORD=", "JIBRI_RECORDER_PASSWORD=$jibriRecorderPassword"
            }
            
            if (-not ($envContent -match "JIBRI_XMPP_PASSWORD=.*[a-zA-Z0-9]")) {
                $jibriXmppPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
                $envContent = $envContent -replace "JIBRI_XMPP_PASSWORD=", "JIBRI_XMPP_PASSWORD=$jibriXmppPassword"
            }
            
            # Try to get JWT settings from Telehealth .env if it exists
            if (Test-Path "$TelehealthDir\.env") {
                try {
                    $telehealthEnv = Get-Content "$TelehealthDir\.env"
                    $jitsiAppIdMatch = $telehealthEnv | Select-String -Pattern "^JITSI_APP_ID=(.*)$"
                    $jitsiAppSecretMatch = $telehealthEnv | Select-String -Pattern "^JITSI_APP_SECRET=(.*)$"
                    
                    if ($jitsiAppIdMatch -and $jitsiAppSecretMatch) {
                        $jitsiAppId = $jitsiAppIdMatch.Matches.Groups[1].Value
                        $jitsiAppSecret = $jitsiAppSecretMatch.Matches.Groups[1].Value
                        
                        # Update Jitsi .env file with JWT settings
                        $envContent = $envContent -replace "JWT_APP_ID=.*", "JWT_APP_ID=$jitsiAppId"
                        $envContent = $envContent -replace "JWT_APP_SECRET=.*", "JWT_APP_SECRET=$jitsiAppSecret"
                        
                        Write-Host "Updated Jitsi JWT settings from Telehealth .env" -ForegroundColor Green
        } else {
                        Write-Host "Jitsi JWT settings not found in Telehealth .env" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "Error reading Telehealth .env: $_" -ForegroundColor Yellow
                }
            }
            
            # Write the updated content to the target file
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Updated Jitsi .env file at: $envTargetPath" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Error creating Jitsi .env file: $_" -ForegroundColor Red
            return $false
        }
    }
    else {
        Write-Host "Jitsi .env.example file not found at: $envExamplePath" -ForegroundColor Yellow
        
        # Create a basic .env file if .env.example doesn't exist
        try {
            $envContent = @"
# Basic Jitsi .env file for $Environment environment
# Generated: $(Get-Date -Format "MM/dd/yyyy HH:mm:ss")
COMPOSE_PROJECT_NAME=$Project-jitsi
HTTP_PORT=$($envConfig.Config.containerPorts.jitsi.http)
HTTPS_PORT=$($envConfig.Config.containerPorts.jitsi.https)
XMPP_PORT=$($envConfig.Config.containerPorts.jitsi.xmpp)
JVB_PORT=$($envConfig.Config.containerPorts.jitsi.jvb)
PUBLIC_URL=https://$($envConfig.Domains.jitsi)

# Network configuration
FRONTEND_NETWORK=$($envConfig.FrontendNetwork)
PROXY_NETWORK=$($envConfig.ProxyNetwork)
DEFAULT_NETWORK=$($envConfig.ProjectName)-jitsi-default

# Authentication settings
ENABLE_AUTH=1
AUTH_TYPE=jwt
JWT_APP_ID=telehealth
JWT_APP_SECRET=OafDjrVt8r

# XMPP passwords
JICOFO_AUTH_PASSWORD=$(-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_}))
JVB_AUTH_PASSWORD=$(-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_}))
JIGASI_XMPP_PASSWORD=$(-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_}))
JIBRI_RECORDER_PASSWORD=$(-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_}))
JIBRI_XMPP_PASSWORD=$(-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_}))

# Jitsi image version
JITSI_IMAGE_VERSION=stable-7648-4
"@
            
            # Try to get JWT settings from Telehealth .env if it exists
            if (Test-Path "$TelehealthDir\.env") {
                try {
                    $telehealthEnv = Get-Content "$TelehealthDir\.env"
                    $jitsiAppIdMatch = $telehealthEnv | Select-String -Pattern "^JITSI_APP_ID=(.*)$"
                    $jitsiAppSecretMatch = $telehealthEnv | Select-String -Pattern "^JITSI_APP_SECRET=(.*)$"
                    
                    if ($jitsiAppIdMatch -and $jitsiAppSecretMatch) {
                        $jitsiAppId = $jitsiAppIdMatch.Matches.Groups[1].Value
                        $jitsiAppSecret = $jitsiAppSecretMatch.Matches.Groups[1].Value
                        
                        # Update Jitsi .env file with JWT settings
                        $envContent = $envContent -replace "JWT_APP_ID=.*", "JWT_APP_ID=$jitsiAppId"
                        $envContent = $envContent -replace "JWT_APP_SECRET=.*", "JWT_APP_SECRET=$jitsiAppSecret"
                        
                        Write-Host "Updated Jitsi JWT settings from Telehealth .env" -ForegroundColor Green
                    }
            } catch {
                    Write-Host "Error reading Telehealth .env: $_" -ForegroundColor Yellow
                }
            }
            
            # Write the content to the target file
            Set-Content -Path $envTargetPath -Value $envContent
            Write-Host "Created basic Jitsi .env file at: $envTargetPath" -ForegroundColor Yellow
            return $true
        }
        catch {
            Write-Host "Error creating basic Jitsi .env file: $_" -ForegroundColor Red
            return $false
        }
    }
}

# Function to compare file hashes and only copy if different
function Copy-IfDifferent {
    param (
        [string]$SourcePath,
        [string]$DestinationPath,
        [switch]$Recurse,
        [string[]]$Exclude
    )
    
    try {
        # If destination doesn't exist, just copy
        if (-not (Test-Path $DestinationPath)) {
            if ($Recurse) {
                Copy-Item -Path $SourcePath -Destination $DestinationPath -Recurse -Force -Exclude $Exclude
            } else {
                Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
            }
            Write-Host "Copied new file/directory: $DestinationPath" -ForegroundColor Green
            return $true
        }
        
        # If it's a directory and recursive is specified
        if ((Get-Item $SourcePath).PSIsContainer -and $Recurse) {
            $sourceFiles = Get-ChildItem -Path $SourcePath -Recurse -File | Where-Object { 
                # Basic exclusions
                ($Exclude -notcontains $_.Name) -and
                ($_.FullName -notlike "*\\node_modules\\*") -and
                ($_.FullName -notlike "*\\vendor\\*") -and
                # Conditional .git exclusion: Include .git files only if in DevMode
                ($script:DevMode -or ($_.FullName -notlike "*\\.git\\*")) # Keep if DevMode OR not in .git
            }
            $copied = $false
            
            foreach ($sourceFile in $sourceFiles) {
                try {
                    $relativePath = $sourceFile.FullName.Substring($SourcePath.Length)
                    $destFile = Join-Path $DestinationPath $relativePath
                    
                    # Create directory structure if it doesn't exist
                    $destDir = Split-Path $destFile -Parent
                    if (-not (Test-Path $destDir)) {
                        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    }
                    
                    # Compare files based on existence, size, and last write time
                    if (-not (Test-Path $destFile)) {
                        # File doesn't exist in destination
                        Copy-Item -Path $sourceFile.FullName -Destination $destFile -Force
                        Write-Host "Copied new: $relativePath" -ForegroundColor Green
                        $copied = $true
            } else {
                        $destFileInfo = Get-Item $destFile
                        if ($sourceFile.Length -ne $destFileInfo.Length -or 
                            $sourceFile.LastWriteTime -gt $destFileInfo.LastWriteTime) {
                            # File size different or source is newer
                            Copy-Item -Path $sourceFile.FullName -Destination $destFile -Force
                            Write-Host "Updated: $relativePath" -ForegroundColor Green
                            $copied = $true
                        }
                    }
                }
                catch {
                    Write-Host "Error processing $($sourceFile.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
                    continue
                }
            }
            return $copied
        }
        # For single files
        elseif (-not (Get-Item $SourcePath).PSIsContainer) {
            $sourceFile = Get-Item $SourcePath
            $destFile = Get-Item $DestinationPath -ErrorAction SilentlyContinue
            
            if (-not $destFile -or 
                $sourceFile.Length -ne $destFile.Length -or 
                $sourceFile.LastWriteTime -gt $destFile.LastWriteTime) {
                Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
                Write-Host "Updated: $DestinationPath" -ForegroundColor Green
                return $true
            }
        }
        
        return $false
    }
    catch {
        Write-Host "Error copying file/directory: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Function to copy and set up Jitsi folder
function Copy-JitsiFolder {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment,
        [bool]$DevMode
    )
    
    try {
        # Create target directory if it doesn't exist
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Write-Host "Created Jitsi target directory at: $TargetDir" -ForegroundColor Green
        }
        
        # Step 1: Copy everything to target directory, excluding .git
        Write-Host "Copying Jitsi folder from: $SourceDir to $TargetDir" -ForegroundColor Yellow
        $copyResult = Copy-IfDifferent -SourcePath "$SourceDir" -DestinationPath $TargetDir -Recurse -Exclude @(".git")
        if ($copyResult) {
            Write-Host "Updated Jitsi files" -ForegroundColor Green
        } else {
            Write-Host "Jitsi files are up to date" -ForegroundColor Green
        }
        
        # Step 2: Create/update the .env file
        Write-Host "Setting up Jitsi .env file..." -ForegroundColor Yellow
        $envSuccess = Copy-JitsiEnvFile -SourceDir $SourceDir -TargetDir $TargetDir -Environment $Environment
        if (-not $envSuccess) {
            Write-Host "Warning: Failed to create/update Jitsi .env file" -ForegroundColor Yellow
        }
        
        # Step 3: Select and copy the appropriate docker-compose file
        $dockerComposeSource = if ($DevMode) {
            if (Test-Path "$SourceDir\docker-compose.yml") {
                "$SourceDir\docker-compose.yml"
                    } else {
                Write-Host "Warning: docker-compose.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        } else {
            if (Test-Path "$SourceDir\docker-compose.yml") {
                "$SourceDir\docker-compose.yml"
            } else {
                Write-Host "Warning: docker-compose.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        }
        
        if (Test-Path $dockerComposeSource) {
            Write-Host "Copying Jitsi docker-compose file from $dockerComposeSource" -ForegroundColor Yellow
            Copy-Item -Path $dockerComposeSource -Destination "$TargetDir\docker-compose.yml" -Force
            Write-Host "Copied Jitsi docker-compose file successfully" -ForegroundColor Green
            
            # Step 4: Update the docker-compose file with environment variables
            Write-Host "Updating Jitsi docker-compose file..." -ForegroundColor Yellow
            $updateSuccess = Update-DockerComposeFile -FilePath "$TargetDir\docker-compose.yml" -Component "Jitsi"
            if ($updateSuccess) {
                Write-Host "Successfully updated Jitsi docker-compose file" -ForegroundColor Green
                    } else {
                Write-Host "Warning: Failed to update Jitsi docker-compose file" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Warning: No docker-compose file found for Jitsi" -ForegroundColor Yellow
        }
        
            return $true
    } catch {
        Write-Host "Error setting up Jitsi folder: $_" -ForegroundColor Red
        return $false
    }
}

# Function to copy and set up Telehealth folder
function Copy-TelehealthFolder {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment,
        [bool]$DevMode
    )
    
    try {
        # Create target directory if it doesn't exist
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Write-Host "Created Telehealth target directory at: $TargetDir" -ForegroundColor Green
        }
        
        # Step 1: Copy everything to target directory, excluding .git
        Write-Host "Copying Telehealth folder from: $SourceDir to $TargetDir" -ForegroundColor Yellow
        $copyResult = Copy-IfDifferent -SourcePath "$SourceDir" -DestinationPath $TargetDir -Recurse -Exclude @(".git")
        if ($copyResult) {
            Write-Host "Updated Telehealth files" -ForegroundColor Green
        } else {
            Write-Host "Telehealth files are up to date" -ForegroundColor Green
        }
        
        # Step 2: Create/update the .env file
        Write-Host "Setting up Telehealth .env file..." -ForegroundColor Yellow
        $envSuccess = Copy-TelehealthEnvFile -SourceDir $SourceDir -TargetDir $TargetDir -Environment $Environment
        if (-not $envSuccess) {
            Write-Host "Warning: Failed to create/update Telehealth .env file" -ForegroundColor Yellow
        }
        
        # Step 3: Select and copy the appropriate docker-compose file
        $dockerComposeSource = if ($DevMode) {
            if (Test-Path "$SourceDir\docker-compose.dev.yml") {
                "$SourceDir\docker-compose.dev.yml"
            } else {
                Write-Host "Warning: docker-compose.dev.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        } else {
            if (Test-Path "$SourceDir\docker-compose.prod.yml") {
                "$SourceDir\docker-compose.prod.yml"
            } else {
                Write-Host "Warning: docker-compose.prod.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        }
        
        if (Test-Path $dockerComposeSource) {
            Write-Host "Copying Telehealth docker-compose file from $dockerComposeSource" -ForegroundColor Yellow
            Copy-Item -Path $dockerComposeSource -Destination "$TargetDir\docker-compose.yml" -Force
            Write-Host "Copied Telehealth docker-compose file successfully" -ForegroundColor Green
            
            # Step 4: Update the docker-compose file with environment variables
            Write-Host "Updating Telehealth docker-compose file..." -ForegroundColor Yellow
            $updateSuccess = Update-DockerComposeFile -FilePath "$TargetDir\docker-compose.yml" -Component "telehealth"
            if ($updateSuccess) {
                Write-Host "Successfully updated Telehealth docker-compose file" -ForegroundColor Green
            } else {
                Write-Host "Warning: Failed to update Telehealth docker-compose file" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Warning: No docker-compose file found for Telehealth" -ForegroundColor Yellow
        }
        
        return $true
    } catch {
        Write-Host "Error setting up Telehealth folder: $_" -ForegroundColor Red
        return $false
    }
}

# Function to update Dockerfile to use newer Ubuntu version and proper PHP setup
function Update-DevDockerfile {
    param (
        [string]$TargetDir
    )
    
    try {
        $dockerfilePath = "$TargetDir\dockerfiles\dev\Dockerfile"
        $nginxConfigPath = "$TargetDir\dockerfiles\dev\openemr.conf"
        
        if (Test-Path $dockerfilePath) {
            Write-Host "Updating dev Dockerfile..." -ForegroundColor Yellow
            
            # Read the Dockerfile content
            $dockerfileContent = Get-Content -Path $dockerfilePath -Raw
            
            # Check if this is an older Dockerfile using Ubuntu 23.04
            if ($dockerfileContent -match "FROM ubuntu:23\.04") {
                Write-Host "Found Ubuntu 23.04 in Dockerfile, updating to 24.04 with proper PHP PPA" -ForegroundColor Green
                
                # Replace the FROM line
                $dockerfileContent = $dockerfileContent -replace "FROM ubuntu:23\.04", "FROM ubuntu:24.04"
                
                # Add the software-properties-common and PPA setup after the DEBIAN_FRONTEND line
                if ($dockerfileContent -match "ENV DEBIAN_FRONTEND noninteractive") {
                    $newPpaSetup = @"
ENV DEBIAN_FRONTEND noninteractive

# Add software-properties-common for add-apt-repository
RUN apt update \
    && apt install -y software-properties-common

# Add PHP PPA (needed for PHP 8.1 on Ubuntu 24.04)
RUN LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
"@
                    $dockerfileContent = $dockerfileContent -replace "ENV DEBIAN_FRONTEND noninteractive", $newPpaSetup
                }
                
                # Fix the Ubuntu user modification to handle missing user case
                if ($dockerfileContent -match "RUN usermod -u 10001 ubuntu && groupmod -g 10001 ubuntu") {
                    $dockerfileContent = $dockerfileContent -replace "RUN usermod -u 10001 ubuntu && groupmod -g 10001 ubuntu", "RUN usermod -u 10001 ubuntu || true`nRUN groupmod -g 10001 ubuntu || true"
                }
                
                # Remove software-properties-common from the first apt install if it's already being installed separately
                if ($dockerfileContent -match "apt-transport-https software-properties-common nginx supervisor") {
                    $dockerfileContent = $dockerfileContent -replace "apt-transport-https software-properties-common nginx supervisor", "apt-transport-https nginx supervisor"
                }
                }
            
            # Uncomment the COPY commands for configuration files
            #$dockerfileContent = $dockerfileContent -replace "#COPY php\.ini.*", "COPY php.ini /etc/php/8.1/fpm/php.ini"
            #$dockerfileContent = $dockerfileContent -replace "#COPY openemr\.conf.*", "COPY openemr.conf /etc/nginx/sites-available/openemr.local"
            #$dockerfileContent = $dockerfileContent -replace "#COPY supervisord\.conf.*", "COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf"
                
                # Write the updated content back to the file
                Set-Content -Path $dockerfilePath -Value $dockerfileContent
            Write-Host "Successfully updated Dockerfile at: $dockerfilePath" -ForegroundColor Green
            
            # Now update the Nginx configuration if it exists
            if (Test-Path $nginxConfigPath) {
                #Write-Host "Updating Nginx configuration to allow setup access..." -ForegroundColor Yellow
                #$nginxContent = Get-Content -Path $nginxConfigPath -Raw
                
                # Comment out the block that denies access to setup files
                ##$nginxContent = $nginxContent -replace "(?m)^(\s*location\s+~\*\s+\^/\(admin\|setup\|acl_setup\|acl_upgrade\|sl_convert\|sql_upgrade\|gacl/setup\|ippf_upgrade\|sql_patch\)\\\.php\s*\{[^}]*\})", "#$1"
                
                # Add a new block that allows access to setup files
                ##$setupBlock = @"
                # Allow access to setup files in development mode
                #location ~* ^/(admin|setup|acl_setup|acl_upgrade|sl_convert|sql_upgrade|gacl/setup|ippf_upgrade|sql_patch)\.php {
                #fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
                #fastcgi_pass unix:/run/php/php8.1-fpm.sock;
                #include fastcgi_params;
                #}
                #"@
                
                # Insert the new block after the commented out block
                #$nginxContent = $nginxContent -replace "(?m)#\s*location\s+~\*\s+\^/\(admin\|setup.*?\}", "`$0`n$setupBlock"
                
                # Write the updated content back to the file
                #Set-Content -Path $nginxConfigPath -Value $nginxContent
                #Write-Host "Successfully updated Nginx configuration at: $nginxConfigPath" -ForegroundColor Green
            } else {
                Write-Host "Nginx configuration file not found at: $nginxConfigPath" -ForegroundColor Yellow
            }
            
            return $true
        } else {
            Write-Host "Dockerfile not found at: $dockerfilePath" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "Error updating Dockerfile: $_" -ForegroundColor Red
        return $false
    }
}

# Function to copy and set up OpenEMR folder
function Copy-OpenEMRFolder {
    param (
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Environment,
        [bool]$DevMode
    )
    
    try {
        # Create target directory if it doesn't exist
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Write-Host "Created OpenEMR target directory at: $TargetDir" -ForegroundColor Green
        }
        
        # Step 1: Detect repository structure and copy files
        # Only treat as official OpenEMR if we're explicitly using the official project
        $isOfficialOpenEMR = ($Project -eq "official") -and (Test-Path "$SourceDir\docker\production\docker-compose.yml")
        Write-Host "Using $(if ($isOfficialOpenEMR) { 'official' } else { 'custom' }) OpenEMR repository from: $SourceDir" -ForegroundColor Green
        
        # Copy files with hash comparison
        Write-Host "Copying OpenEMR folder from: $SourceDir to $TargetDir" -ForegroundColor Yellow
        $copyResult = Copy-IfDifferent -SourcePath "$SourceDir" -DestinationPath $TargetDir -Recurse -Exclude @(".git")
        if ($copyResult) {
            Write-Host "Updated OpenEMR files" -ForegroundColor Green
        } else {
            Write-Host "OpenEMR files are up to date" -ForegroundColor Green
        }
        
        # For non-official OpenEMR, copy dockerfiles and mysql folders to base directory
        if (-not $isOfficialOpenEMR) {
            # Copy dockerfiles folder
            $dockerfilesSource = "$SourceDir\ciips\docker\dockerfiles"
            $dockerfilesTarget = "$TargetDir"
            if (Test-Path $dockerfilesSource) {
                Write-Host "Copying dockerfiles folder to base directory..." -ForegroundColor Yellow
                Copy-Item -Path $dockerfilesSource -Destination $dockerfilesTarget -Recurse -Force
                Write-Host "Copied dockerfiles folder to: $dockerfilesTarget" -ForegroundColor Green
            }
            
            # Copy mysql folder
            $mysqlSource = "$SourceDir\ciips\docker\sql"
            $mysqlTarget = "$TargetDir"
            if (Test-Path $mysqlSource) {
                Write-Host "Copying mysql folder to base directory..." -ForegroundColor Yellow
                Copy-Item -Path $mysqlSource -Destination $mysqlTarget -Recurse -Force
                Write-Host "Copied mysql folder to: $mysqlTarget" -ForegroundColor Green
            }
        }
        
        # Update Dockerfile for dev mode if needed
        if ($DevMode -and -not $isOfficialOpenEMR) {
            Write-Host "DevMode enabled - updating Dockerfile to use newer Ubuntu version..." -ForegroundColor Yellow
            # Ensure the directory structure exists
            $dockerfileDir = "$TargetDir\dockerfiles\dev"
            if (-not (Test-Path $dockerfileDir)) {
                New-Item -ItemType Directory -Path $dockerfileDir -Force | Out-Null
                Write-Host "Created directory structure for dev Dockerfile at: $dockerfileDir" -ForegroundColor Green
            }
            Update-DevDockerfile -TargetDir $TargetDir
        }
        
        # Step 2: Create/update the .env file
        Write-Host "Setting up OpenEMR .env file..." -ForegroundColor Yellow
        $envSuccess = Copy-OpenEMREnvFile -SourceDir $SourceDir -TargetDir $TargetDir -Environment $Environment
        if (-not $envSuccess) {
            Write-Host "Warning: Failed to create/update OpenEMR .env file" -ForegroundColor Yellow
        }
        
        # Step 3: Select and copy the appropriate docker-compose file
        $dockerComposeSource = if ($isOfficialOpenEMR) {
            "$SourceDir\docker\production\docker-compose.yml"
        } elseif ($DevMode) {
            if (Test-Path "$SourceDir\ciips\docker\docker-compose.dev.yml") {
                "$SourceDir\ciips\docker\docker-compose.dev.yml"
            } else {
                Write-Host "Warning: docker-compose.dev.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        } else {
            if (Test-Path "$SourceDir\ciips\docker\docker-compose.prod.yml") {
            "$SourceDir\ciips\docker\docker-compose.prod.yml"
        } else {
                Write-Host "Warning: docker-compose.prod.yml not found, falling back to docker-compose.yml" -ForegroundColor Yellow
                "$SourceDir\docker-compose.yml"
            }
        }
        
        if (Test-Path $dockerComposeSource) {
            Write-Host "Copying OpenEMR docker-compose file from $dockerComposeSource" -ForegroundColor Yellow
            Copy-Item -Path $dockerComposeSource -Destination "$TargetDir\docker-compose.yml" -Force
            Write-Host "Copied OpenEMR docker-compose file successfully" -ForegroundColor Green

            # If this is the official OpenEMR, update the docker-compose content
            if ($isOfficialOpenEMR) {
                Write-Host "Updating official OpenEMR docker-compose file..." -ForegroundColor Yellow
                $dockerComposeContent = Get-Content -Path "$TargetDir\docker-compose.yml" -Raw

                # Replace hardcoded port mappings with environment variables
                $dockerComposeContent = $dockerComposeContent -replace "(\s+- )80:80", '$1${HTTP_PORT}:80'
                $dockerComposeContent = $dockerComposeContent -replace "(\s+- )443:443", '$1${HTTPS_PORT}:443'
                
                # Update the project name in the docker-compose file
                if ($dockerComposeContent -notmatch "name:") {
                    $dockerComposeContent = $dockerComposeContent -replace "version: '3.1'", "version: '3.1'`nname: $($envConfig.ProjectName)"
                }

                # Save the updated content
                Set-Content -Path "$TargetDir\docker-compose.yml" -Value $dockerComposeContent
                Write-Host "Updated official OpenEMR docker-compose file with environment variables" -ForegroundColor Green
            }
            
            # Step 4: Update the docker-compose file with environment variables
            Write-Host "Updating OpenEMR docker-compose file..." -ForegroundColor Yellow
            $updateSuccess = Update-DockerComposeFile -FilePath "$TargetDir\docker-compose.yml" -Component "OpenEMR"
            if ($updateSuccess) {
                Write-Host "Successfully updated OpenEMR docker-compose file" -ForegroundColor Green
        } else {
                Write-Host "Warning: Failed to update OpenEMR docker-compose file" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Warning: No docker-compose file found for OpenEMR" -ForegroundColor Yellow
        }
        
        return $true
    } catch {
        Write-Host "Error setting up OpenEMR folder: $_" -ForegroundColor Red
        return $false
    }
}

# Function to create environment-specific configuration files
function Create-EnvironmentFiles {
    try {
        # Create component subdirectories
        $openemrTargetDir = "$targetDir\$($envConfig.FolderNames.openemr)"
        $telehealthTargetDir = "$targetDir\$($envConfig.FolderNames.telehealth)"
        $jitsiTargetDir = "$targetDir\$($envConfig.FolderNames.jitsi)"
        $proxyTargetDir = "$targetDir\$($envConfig.FolderNames.proxy)"
        $sslTargetDir = "$targetDir\ssl"
        
        # Create directories if they don't exist
        New-Item -ItemType Directory -Path $openemrTargetDir -Force | Out-Null
        New-Item -ItemType Directory -Path $telehealthTargetDir -Force | Out-Null
        New-Item -ItemType Directory -Path $jitsiTargetDir -Force | Out-Null
        New-Item -ItemType Directory -Path $proxyTargetDir -Force | Out-Null
        New-Item -ItemType Directory -Path $sslTargetDir -Force | Out-Null
        
        # OpenEMR Setup
        Write-Host "Setting up OpenEMR..." -ForegroundColor Cyan
        # Use the correct OpenEMR source directory based on project
        if ($Project -eq "official") {
            Write-Host "Using official OpenEMR repository for setup..." -ForegroundColor Green
            Copy-OpenEMRFolder -SourceDir $openemrSourceDir -TargetDir $openemrTargetDir -Environment $Environment -DevMode $script:DevMode
        } else {
            # Default behavior for other projects
        Copy-OpenEMRFolder -SourceDir "$sourceDir\openemr-telesalud" -TargetDir $openemrTargetDir -Environment $Environment -DevMode $script:DevMode
        }
        
        # Telehealth Setup
        Write-Host "Setting up Telehealth..." -ForegroundColor Cyan
        Copy-TelehealthFolder -SourceDir $telehealthSourceDir -TargetDir $telehealthTargetDir -Environment $Environment -DevMode $script:DevMode
        
        # Jitsi Setup
        Write-Host "Setting up Jitsi..." -ForegroundColor Cyan
        Copy-JitsiFolder -SourceDir "$telehealthSourceDir\jitsi-docker" -TargetDir $jitsiTargetDir -Environment $Environment -TelehealthDir $telehealthTargetDir
        
        # Proxy Setup
        Write-Host "Setting up Proxy..." -ForegroundColor Cyan
        Copy-DockerComposeFromSource -SourcePath "$PSScriptRoot\templates\proxy\docker-compose.yml" -TargetPath "$proxyTargetDir\docker-compose.yml" -ComponentName "Proxy"
    
        # Create .env files for other components
        Create-EnvironmentVariableFile -TargetDir $proxyTargetDir -Component "proxy"
    
        # Create start and stop scripts
        Create-StartScript
        Create-StopScript
        
        # Create a README file with instructions
        $readmeContent = @"
# $Environment Environment

This directory contains the Docker Compose files and configuration for the $Environment environment.

## Starting the Environment

To start the environment, run:

```
.\start-$Environment.ps1
```

## Stopping the Environment

To stop the environment, run:

```
.\stop-$Environment.ps1
```

## Environment Details

- OpenEMR URL: https://$($envConfig.Domains.openemr)
- Telehealth URL: https://$($envConfig.Domains.telehealth)
- Jitsi URL: https://$($envConfig.Domains.jitsi)
- Proxy Admin URL: http://localhost:$($envConfig.Config.npmPorts.admin)

## Environment Variables

Environment-specific variables are stored in .env files in each component directory.
"@
        
        Set-Content -Path "$targetDir\README.md" -Value $readmeContent -Force
        Write-Host "Created README.md with environment instructions" -ForegroundColor Green
        
    } catch {
        Write-Host "Error during environment setup: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Function to handle Docker cleanup with project selection
function Cleanup-DockerResourcesWithOptions {
    param (
        [string]$ProjectName,
        [switch]$ForceRemoveVolumes
    )
    
    Write-Host "Docker container cleanup options:" -ForegroundColor Cyan
    Write-Host "1. Clean up only $ProjectName project containers" -ForegroundColor Yellow
    Write-Host "2. Clean up all project containers" -ForegroundColor Yellow
    Write-Host "3. Skip container cleanup" -ForegroundColor Yellow
    
    $cleanupChoice = Get-UserInput -Prompt "Select an option (1-3)" -ValidResponses @("1", "2", "3") -DefaultResponse "1"
    
    switch ($cleanupChoice) {
        "1" {
            Write-Host "Cleaning up containers for project: $ProjectName" -ForegroundColor Yellow
            Cleanup-DockerResources -ProjectName $ProjectName -ForceRemoveVolumes:$ForceRemoveVolumes
        }
        "2" {
            Write-Host "Cleaning up all project containers" -ForegroundColor Yellow
            # Get all running containers
            $allContainers = docker ps -a --format "{{.Names}}"
            if ($allContainers) {
                Write-Host "Found the following containers to remove:" -ForegroundColor Yellow
                $allContainers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                
                $confirm = Get-UserInput -Prompt "Do you want to proceed with removal? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
                if ($confirm -eq "y") {
                    $allContainers | ForEach-Object {
                        Write-Host "Stopping container: $_" -ForegroundColor Yellow
                        docker stop $_ 2>$null
                        Write-Host "Removing container: $_" -ForegroundColor Yellow
                        docker rm $_ 2>$null
                    }
                }
            } else {
                Write-Host "No containers found" -ForegroundColor Yellow
            }
            
            # Handle volumes if requested
            if ($ForceRemoveVolumes) {
                $allVolumes = docker volume ls --format "{{.Name}}"
                if ($allVolumes) {
                    Write-Host "Found the following volumes to remove:" -ForegroundColor Yellow
                    $allVolumes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                    
                    $confirm = Get-UserInput -Prompt "Do you want to proceed with volume removal? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
                    if ($confirm -eq "y") {
                        $allVolumes | ForEach-Object {
                            Write-Host "Removing volume: $_" -ForegroundColor Yellow
                            docker volume rm $_ 2>$null
                        }
                    }
                }
            }
        }
        "3" {
            Write-Host "Skipping container cleanup" -ForegroundColor Yellow
        }
    }
}

# Function to clean up Docker resources for an environment
function Cleanup-DockerResources {
    param (
        [string]$ProjectName,
        [switch]$ForceRemoveVolumes = $false
    )
    
    Write-Host "Cleaning up Docker resources for project: $ProjectName" -ForegroundColor Yellow
    
    # Stop and remove containers with the project name prefix
    Write-Host "Stopping and removing containers..." -ForegroundColor Yellow
    $containers = docker ps -a --format "{{.Names}}" | Where-Object { $_ -match "$ProjectName" }
    if ($containers) {
        foreach ($container in $containers) {
            Write-Host "  - Stopping and removing container: $container" -ForegroundColor Yellow
            docker stop $container 2>$null
            docker rm $container 2>$null
        }
        Write-Host "All containers removed." -ForegroundColor Green
    } else {
        Write-Host "No containers found for project: $ProjectName" -ForegroundColor Yellow
    }
    
    # Remove networks with the project name prefix
    Write-Host "Removing networks..." -ForegroundColor Yellow
    $networks = docker network ls --format "{{.Name}}" | Where-Object { $_ -match "$ProjectName" }
    if ($networks) {
        foreach ($network in $networks) {
            Write-Host "  - Removing network: $network" -ForegroundColor Yellow
            docker network rm $network 2>$null
        }
        Write-Host "All networks removed." -ForegroundColor Green
    } else {
        Write-Host "No networks found for project: $ProjectName" -ForegroundColor Yellow
    }
    
    # Handle volumes
    if ($ForceRemoveVolumes) {
        $removeVolumes = "y"
    } else {
        $removeVolumes = Get-UserInput -Prompt "Do you want to remove all volumes for this project? This will delete all data. (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
    }
    
    if ($removeVolumes -eq "y") {
        Write-Host "Removing volumes..." -ForegroundColor Yellow
        $volumes = docker volume ls --format "{{.Name}}" | Where-Object { $_ -match "$ProjectName" }
        if ($volumes) {
            foreach ($volume in $volumes) {
                Write-Host "  - Removing volume: $volume" -ForegroundColor Yellow
                docker volume rm $volume 2>$null
            }
            Write-Host "All volumes removed." -ForegroundColor Green
        } else {
            Write-Host "No volumes found for project: $ProjectName" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Volumes will be preserved." -ForegroundColor Yellow
    }
    
    Write-Host "Docker resources cleanup completed." -ForegroundColor Green
}

# Function to safely remove a directory with retries
function Remove-DirectorySafely {
    param (
        [string]$Path,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )
    
    Write-Host "Starting directory removal process for: $Path" -ForegroundColor Yellow
    
    # Check if directory exists
    if (-not (Test-Path $Path)) {
        Write-Host "Directory does not exist: $Path" -ForegroundColor Yellow
        return $true
    }
    
    # Log initial state
    Write-Host "Initial directory contents:" -ForegroundColor Yellow
    Get-ChildItem -Path $Path -Force | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Yellow
    }
    
    # Try to remove the directory with retries
    $retryCount = 0
    $success = $false
    
    while (-not $success -and $retryCount -lt $MaxRetries) {
        try {
            Write-Host "`nAttempt $($retryCount + 1) of $MaxRetries to remove directory..." -ForegroundColor Yellow
            
            # First try to remove read-only attributes
            Write-Host "Removing read-only attributes from files..." -ForegroundColor Yellow
            Get-ChildItem -Path $Path -Recurse -Force | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    Write-Host "  - Removing read-only from: $($_.FullName)" -ForegroundColor Yellow
                    $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
            }
            
            # Force garbage collection before removal
            Write-Host "Running garbage collection..." -ForegroundColor Yellow
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            
            # Then remove the directory
            Write-Host "Attempting to remove directory..." -ForegroundColor Yellow
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            
            # Wait a moment to ensure the removal is complete
            Write-Host "Waiting for removal to complete..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            
            # Verify removal
            if (-not (Test-Path $Path)) {
                $success = $true
                Write-Host "Directory removed successfully: $Path" -ForegroundColor Green
                
                # Double-check with a second verification
                Start-Sleep -Seconds 1
                if (-not (Test-Path $Path)) {
                    Write-Host "Secondary verification: Directory confirmed removed" -ForegroundColor Green
                } else {
                    Write-Host "WARNING: Directory reappeared after removal!" -ForegroundColor Red
                    $success = $false
                }
            } else {
                Write-Host "Directory still exists after removal attempt" -ForegroundColor Red
            }
        }
        catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            Write-Host "Error removing directory (Attempt $retryCount of $MaxRetries): $errorMessage" -ForegroundColor Red
            
            if ($retryCount -lt $MaxRetries) {
                Write-Host "Waiting $RetryDelaySeconds seconds before retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
                
                # Try to identify and close any open handles
                Write-Host "Attempting to close any open handles..." -ForegroundColor Yellow
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            }
        }
    }
    
    # Final verification
    Write-Host "`nPerforming final verification..." -ForegroundColor Yellow
    $directoryExists = Test-Path $Path
    if ($directoryExists) {
        Write-Host "WARNING: Directory still exists after all removal attempts: $Path" -ForegroundColor Red
        Write-Host "Remaining contents:" -ForegroundColor Red
        Get-ChildItem -Path $Path -Force | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Red
        }
        Write-Host "You may need to manually delete this directory." -ForegroundColor Red
        return $false
    } else {
        Write-Host "Final verification: Directory successfully removed" -ForegroundColor Green
        return $true
    }
}

# Function to get container by component pattern
function Get-Container {
    param (
        [string]$ComponentPattern,
        [string]$Suffix = ""
    )
    
    # Build a pattern that will match containers for this environment
    $containerPattern = "^$baseProjectName-$ComponentPattern$Suffix$"
    
    # Try to find containers matching the pattern
    $container = docker ps --format "{{.Names}}" | Where-Object { $_ -match $containerPattern } | Select-Object -First 1
    
    return $container
}

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

# Function to handle Jitsi backup
function Backup-Jitsi {
    param (
        [string]$BackupDir,
        [string]$ProjectName
    )
    
    Write-Host "Backing up Jitsi configuration..." -ForegroundColor Yellow
    
    # Try to get shared Jitsi container first
    $sharedJitsiContainer = Get-SharedJitsiContainer
    if ($sharedJitsiContainer) {
        Write-Host "Found shared Jitsi container: $sharedJitsiContainer" -ForegroundColor Green
        $jitsiContainer = $sharedJitsiContainer
    } else {
        # Fall back to environment-specific Jitsi container
        $envJitsiContainer = Get-EnvironmentJitsiContainer -ProjectName $ProjectName
        if ($envJitsiContainer) {
            Write-Host "Found environment-specific Jitsi container: $envJitsiContainer" -ForegroundColor Green
            $jitsiContainer = $envJitsiContainer
        } else {
            Write-Host "No Jitsi container found. Skipping Jitsi backup." -ForegroundColor Yellow
            return
        }
    }
    
    # Create Jitsi backup directory
    $jitsiBackupDir = Join-Path $BackupDir "jitsi"
    if (-not (Test-Path $jitsiBackupDir)) {
        New-Item -ItemType Directory -Path $jitsiBackupDir -Force | Out-Null
    }
    
    # Backup Jitsi configuration
    Write-Host "Backing up Jitsi configuration from container: $jitsiContainer" -ForegroundColor Yellow
    docker cp "${jitsiContainer}:/config" "$jitsiBackupDir/config"
    docker cp "${jitsiContainer}:/config/meetme-jitsi.cfg.lua" "$jitsiBackupDir/meetme-jitsi.cfg.lua"
    
    Write-Host "Jitsi backup completed successfully." -ForegroundColor Green
}

# Function to handle Jitsi restore
function Restore-Jitsi {
    param (
        [string]$BackupDir,
        [string]$ProjectName
    )
    
    Write-Host "Restoring Jitsi configuration..." -ForegroundColor Yellow
    
    # Try to get shared Jitsi container first
    $sharedJitsiContainer = Get-SharedJitsiContainer
    if ($sharedJitsiContainer) {
        Write-Host "Found shared Jitsi container: $sharedJitsiContainer" -ForegroundColor Green
        $jitsiContainer = $sharedJitsiContainer
    } else {
        # Fall back to environment-specific Jitsi container
        $envJitsiContainer = Get-EnvironmentJitsiContainer -ProjectName $ProjectName
        if ($envJitsiContainer) {
            Write-Host "Found environment-specific Jitsi container: $envJitsiContainer" -ForegroundColor Green
            $jitsiContainer = $envJitsiContainer
        } else {
            Write-Host "No Jitsi container found. Skipping Jitsi restore." -ForegroundColor Yellow
            return
        }
    }
    
    # Check if backup exists
    $jitsiBackupDir = Join-Path $BackupDir "jitsi"
    if (-not (Test-Path $jitsiBackupDir)) {
        Write-Host "No Jitsi backup found at: $jitsiBackupDir" -ForegroundColor Yellow
        return
    }
    
    # Restore Jitsi configuration
    Write-Host "Restoring Jitsi configuration to container: $jitsiContainer" -ForegroundColor Yellow
    docker cp "$jitsiBackupDir/config" "${jitsiContainer}:/config"
    docker cp "$jitsiBackupDir/meetme-jitsi.cfg.lua" "${jitsiContainer}:/config/meetme-jitsi.cfg.lua"
    
    # Restart Jitsi container to apply changes
    Write-Host "Restarting Jitsi container..." -ForegroundColor Yellow
    docker restart $jitsiContainer
    
    Write-Host "Jitsi restore completed successfully." -ForegroundColor Green
}

# Function to handle network setup
function Setup-Networks {
    param (
        [string]$ProjectName
    )
    
    Write-Host "Setting up Docker networks..." -ForegroundColor Cyan
    
    # Create shared network if it doesn't exist
    $sharedNetworkName = "aiotp-shared-network"
    $sharedNetworkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $sharedNetworkName }
    
    if (-not $sharedNetworkExists) {
        Write-Host "Creating shared network: $sharedNetworkName" -ForegroundColor Yellow
        docker network create $sharedNetworkName
    } else {
        Write-Host "Shared network already exists: $sharedNetworkName" -ForegroundColor Green
    }
    
    # Create environment-specific network if it doesn't exist
    $envNetworkName = "$ProjectName-network"
    $envNetworkExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $envNetworkName }
    
    if (-not $envNetworkExists) {
        Write-Host "Creating environment network: $envNetworkName" -ForegroundColor Yellow
        docker network create $envNetworkName
    } else {
        Write-Host "Environment network already exists: $envNetworkName" -ForegroundColor Green
    }
    
    # Get containers
    $openemrContainer = Get-Container -ComponentPattern "openemr" -Suffix "-1"
    $telehealthAppContainer = Get-Container -ComponentPattern "telehealth" -Suffix "-app-1"
    $telehealthWebContainer = Get-Container -ComponentPattern "telehealth" -Suffix "-web-1"
    $sharedJitsiContainer = Get-SharedJitsiContainer
    $envJitsiContainer = Get-EnvironmentJitsiContainer -ProjectName $ProjectName
    
    # Connect containers to appropriate networks
    if ($openemrContainer) {
        Write-Host "Connecting OpenEMR to networks..." -ForegroundColor Yellow
        docker network connect $envNetworkName $openemrContainer
        docker network connect $sharedNetworkName $openemrContainer
    }
    
    if ($telehealthAppContainer) {
        Write-Host "Connecting Telehealth App to networks..." -ForegroundColor Yellow
        docker network connect $envNetworkName $telehealthAppContainer
        docker network connect $sharedNetworkName $telehealthAppContainer
    }
    
    if ($telehealthWebContainer) {
        Write-Host "Connecting Telehealth Web to networks..." -ForegroundColor Yellow
        docker network connect $envNetworkName $telehealthWebContainer
        docker network connect $sharedNetworkName $telehealthWebContainer
    }
    
    if ($sharedJitsiContainer) {
        Write-Host "Connecting shared Jitsi to shared network..." -ForegroundColor Yellow
        docker network connect $sharedNetworkName $sharedJitsiContainer
    }
    
    if ($envJitsiContainer) {
        Write-Host "Connecting environment-specific Jitsi to networks..." -ForegroundColor Yellow
        docker network connect $envNetworkName $envJitsiContainer
        docker network connect $sharedNetworkName $envJitsiContainer
    }
    
    Write-Host "Network setup complete!" -ForegroundColor Green
}

# Update the main backup function to use the new Jitsi backup function
function Backup-Environment {
    param (
        [string]$Environment,
        [string]$BackupDir
    )
    
    # ... existing backup code ...
    
    # Add Jitsi backup
    Backup-Jitsi -BackupDir $BackupDir -ProjectName $baseProjectName
    
    # ... rest of existing backup code ...
}

# Update the main restore function to use the new Jitsi restore function
function Restore-Environment {
    param (
        [string]$Environment,
        [string]$BackupDir
    )
    
    # ... existing restore code ...
    
    # Add Jitsi restore
    Restore-Jitsi -BackupDir $BackupDir -ProjectName $baseProjectName
    
    # ... rest of existing restore code ...
}

# Update the main setup function to use the new network setup function
function Setup-Environment {
    param (
        [string]$Environment
    )
    
    # ... existing setup code ...
    
    # Add network setup
    Setup-Networks -ProjectName $baseProjectName
    
    # ... rest of existing setup code ...
}

# For backward compatibility
if ($StagingEnvironment) {
    $Environment = "staging"
}

# Validate environment parameter
if ([string]::IsNullOrEmpty($Environment)) {
    Write-ErrorAndExit "Environment parameter is required. Valid values: staging, dev, test"
}

try {
    # Get environment configuration from our central config
    Write-Host "Loading environment configuration for project: $Project" -ForegroundColor Yellow
    $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase
    
    # Load network configuration and ensure networks exist
    Write-Host "Setting up Docker networks..." -ForegroundColor Yellow
    $networkConfig = . "$PSScriptRoot\network-setup.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase
    
    # Create timestamp for backup
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $baseDir = Get-Location
    $backupDir = "$baseDir\backups\$timestamp"
    
    # Create backup directory
    Write-Host "Creating backup directory: $backupDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    
    # Define source directories using project name
    $openemrDir = "$baseDir\$($envConfig.SourceFolderNames.openemr)"
    $telehealthDir = "$baseDir\$($envConfig.SourceFolderNames.telehealth)"
    $jitsiDir = "$baseDir\$($envConfig.SourceFolderNames.jitsi)"
    $proxyDir = "$baseDir\$($envConfig.SourceFolderNames.proxy)"
    $sslDir = "$baseDir\ssl"
    
    # Create backup subdirectories
    $openemrBackupDir = "$backupDir\$($envConfig.FolderNames.openemr)"
    $telehealthBackupDir = "$backupDir\$($envConfig.FolderNames.telehealth)"
    $jitsiBackupDir = "$backupDir\$($envConfig.FolderNames.jitsi)"
    $proxyBackupDir = "$backupDir\$($envConfig.FolderNames.proxy)"
    $sslBackupDir = "$backupDir\ssl"
    
    # Create backup subdirectories
    New-Item -ItemType Directory -Path $openemrBackupDir -Force | Out-Null
    New-Item -ItemType Directory -Path $telehealthBackupDir -Force | Out-Null
    New-Item -ItemType Directory -Path $jitsiBackupDir -Force | Out-Null
    New-Item -ItemType Directory -Path $proxyBackupDir -Force | Out-Null
    New-Item -ItemType Directory -Path $sslBackupDir -Force | Out-Null
    
    # Backup OpenEMR

    
    # Define target environment directory
    $targetDir = "$baseDir\$($envConfig.DirectoryName)"
    
    # Check for existing environment directory
    if (Test-Path $targetDir) {
        Write-Host "Environment directory already exists: $targetDir" -ForegroundColor Yellow
        
        $removeExisting = Get-UserInput -Prompt "Do you want to remove the existing environment? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
        
        if ($removeExisting -eq "y") {
            Write-Host "Starting cleanup of existing environment..." -ForegroundColor Yellow
            
            try {
                # Clean up Docker resources first
                Write-Host "Cleaning up Docker resources..." -ForegroundColor Yellow
                Cleanup-DockerResourcesWithOptions -ProjectName $envConfig.ProjectName -ForceRemoveVolumes:$Force
                
                # Then remove the directory using our safer method
                Write-Host "Removing environment directory..." -ForegroundColor Yellow
                $removalSuccess = Remove-DirectorySafely -Path $targetDir
                
                if (-not $removalSuccess) {
                    Write-Host "WARNING: Some files or directories could not be removed from: $targetDir" -ForegroundColor Red
                    Write-Host "This may cause issues with the new environment setup." -ForegroundColor Red
                    
                    $proceed = Get-UserInput -Prompt "Do you want to continue anyway? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
                    if ($proceed -ne "y") {
                        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
                        exit
                    }
                } else {
                    Write-Host "Environment directory successfully removed." -ForegroundColor Green
                }
                
                # Create the directory fresh
                Write-Host "Creating fresh environment directory: $targetDir" -ForegroundColor Yellow
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                
                # Verify the directory is empty
                $remainingItems = Get-ChildItem -Path $targetDir -Force
                if ($remainingItems.Count -gt 0) {
                    Write-Host "WARNING: Directory is not empty after cleanup. Remaining items:" -ForegroundColor Red
                    $remainingItems | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Red }
                } else {
                    Write-Host "Environment directory is clean and ready for new setup." -ForegroundColor Green
                }
                
                # Create environment-specific configuration files
                Write-Host "Creating environment-specific configuration files..." -ForegroundColor Yellow
                Create-EnvironmentFiles
            } catch {
                Write-Host "Error during environment cleanup: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Attempting to continue with existing environment..." -ForegroundColor Yellow
                
                # Ask if user wants to update configuration files
                $updateConfig = Get-UserInput -Prompt "Do you want to update the configuration files in the existing environment? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
                
                if ($updateConfig -eq "y") {
                    Write-Host "Updating environment-specific configuration files..." -ForegroundColor Yellow
                    Create-EnvironmentFiles
                } else {
                    Write-Host "Keeping existing configuration files." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "Using existing environment directory: $targetDir" -ForegroundColor Yellow
            
            # Ask if user wants to update configuration files
            $updateConfig = Get-UserInput -Prompt "Do you want to update the configuration files in the existing environment? (y/n)" -ValidResponses @("y", "n") -DefaultResponse "y"
            
            if ($updateConfig -eq "y") {
                Write-Host "Updating environment-specific configuration files..." -ForegroundColor Yellow
                Create-EnvironmentFiles
            } else {
                Write-Host "Keeping existing configuration files." -ForegroundColor Yellow
            }
        }
    } else {
        # Create the directory
        Write-Host "Creating environment directory: $targetDir" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        
        # Create environment-specific configuration files
        Write-Host "Creating environment-specific configuration files..." -ForegroundColor Yellow
        Create-EnvironmentFiles
    }
    
    # Run setup.ps1 if requested
    if ($RunSetup) {
        Write-Host "`nRunning setup script for $Environment environment..." -ForegroundColor Cyan
        
        # Debug output
        Write-Host "Debug: Environment = $Environment" -ForegroundColor Magenta
        Write-Host "Debug: Project = $Project" -ForegroundColor Magenta
        Write-Host "Debug: DomainBase = $DomainBase" -ForegroundColor Magenta
        Write-Host "Debug: DevMode = $script:DevMode" -ForegroundColor Magenta
        Write-Host "Debug: dirName from envConfig = $($envConfig.DirectoryName)" -ForegroundColor Magenta
        Write-Host "Debug: ARM = $ARM" -ForegroundColor Magenta
        
        # Construct the arguments for setup.ps1
        # Make sure to pass Environment exactly as received
        $setupArgs = @{
            Environment = $Environment.ToString()
            Project = $Project
            DomainBase = $DomainBase
        }
        
        # Add debug output to verify Environment value
        Write-Host "Debug: Passing Environment='$Environment' to setup.ps1" -ForegroundColor Magenta
        
        # Pass the -Force switch if it was provided to this script
        if ($PSBoundParameters.ContainsKey('Force')) {
             $setupArgs.Force = $Force
        }
        
        # Pass the -ARM switch if it was provided to this script
        if ($ARM) {
            $setupArgs.ARM = $true
        }
        
        # Call setup.ps1 with splatting
        & "$PSScriptRoot\setup.ps1" @setupArgs
        
        Write-Host "`nSetup script completed for $Environment environment." -ForegroundColor Green
    } else {
        $armParam = if ($ARM) { " -ARM" } else { "" }
        Write-Host "For full customization, run setup.ps1 manually: .\setup.ps1 -Environment $Environment -Project $Project -DomainBase $DomainBase$armParam" -ForegroundColor Yellow
    }
    
    # Display final success messages
    Write-Host "Environment setup completed successfully!" -ForegroundColor Green
    Write-Host "New environment created at: $targetDir" -ForegroundColor Green
    Write-Host "Backup created at: $backupDir" -ForegroundColor Green
    
    # Display next steps if setup was not run
    if (-not $RunSetup) {
        Write-Host "To complete the setup, run: .\setup.ps1 -Environment $Environment -Project $Project -DomainBase $DomainBase" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Critical error in backup-and-staging.ps1$([char]58) $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
