# Setup script for Official OpenEMR Project
# This script sets up the official OpenEMR with customized port configuration

param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [switch]$Force = $false
)

# Load environment configuration
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project "official"
if (-not $envConfig) {
    Write-Host "Failed to load environment configuration" -ForegroundColor Red
    exit 1
}

Write-Host "Setting up official OpenEMR for environment: $Environment" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# Ensure source repositories are updated
Write-Host "Updating source repositories..." -ForegroundColor Yellow
$repoResult = . "$PSScriptRoot\update-source-repos.ps1" -Project "official" -Force:$Force
if (-not $repoResult.Success) {
    Write-Host "Failed to update source repositories. Check errors above." -ForegroundColor Red
    exit 1
}

$openemrSourceDir = $repoResult.OpenEMRSourceDir
Write-Host "OpenEMR source directory: $openemrSourceDir" -ForegroundColor Green

# Create target directory for environment if it doesn't exist
$targetDir = Join-Path -Path $PSScriptRoot -ChildPath $envConfig.DirectoryName
$openemrTargetDir = Join-Path -Path $targetDir -ChildPath $envConfig.FolderNames.openemr

if (-not (Test-Path -Path $targetDir)) {
    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    Write-Host "Created target directory: $targetDir" -ForegroundColor Green
}

if (-not (Test-Path -Path $openemrTargetDir)) {
    New-Item -Path $openemrTargetDir -ItemType Directory -Force | Out-Null
    Write-Host "Created OpenEMR target directory: $openemrTargetDir" -ForegroundColor Green
}

# Copy docker-compose.yml from the official repository and adapt it
$sourceDockerCompose = Join-Path -Path $openemrSourceDir -ChildPath "docker\production\docker-compose.yml"
$targetDockerCompose = Join-Path -Path $openemrTargetDir -ChildPath "docker-compose.yml"

if (-not (Test-Path -Path $sourceDockerCompose)) {
    Write-Host "Error: Docker Compose file not found at $sourceDockerCompose" -ForegroundColor Red
    exit 1
}

Write-Host "Copying and adapting Docker Compose file..." -ForegroundColor Yellow
$dockerComposeContent = Get-Content -Path $sourceDockerCompose -Raw

# Replace the ports with environment-specific values
$httpPort = $envConfig.Config.containerPorts.openemr.http
$httpsPort = $envConfig.Config.containerPorts.openemr.https

# Use regex to replace port mappings
$dockerComposeContent = $dockerComposeContent -replace '(\s+ports:\s+.*?)(\s+- "80:80")', "`$1`$2`n      - `"$httpPort`:80`""
$dockerComposeContent = $dockerComposeContent -replace '(\s+- "80:80")', "      - `"$httpPort`:80`""
$dockerComposeContent = $dockerComposeContent -replace '(\s+- "443:443")', "      - `"$httpsPort`:443`""

# Add project name to prevent conflicts
$dockerComposeContent = "# Docker Compose for Official OpenEMR - $Environment`n`nversion: '3.1'`nname: $($envConfig.ProjectName)`n" + ($dockerComposeContent -replace "version: '3.1'", "")

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
$envFilePath = Join-Path -Path $openemrTargetDir -ChildPath ".env"
$envFileContent = @"
# Environment file for Official OpenEMR - $Environment
# Generated: $(Get-Date)

COMPOSE_PROJECT_NAME=$($envConfig.ProjectName)
HTTP_PORT=$httpPort
HTTPS_PORT=$httpsPort
"@

Set-Content -Path $envFilePath -Value $envFileContent -Force
Write-Host "Created .env file at $envFilePath" -ForegroundColor Green

# Create networks if they don't exist
Write-Host "Checking networks..." -ForegroundColor Yellow
$frontendNetwork = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $envConfig.FrontendNetwork }
if (-not $frontendNetwork) {
    Write-Host "Creating frontend network: $($envConfig.FrontendNetwork)" -ForegroundColor Yellow
    docker network create $envConfig.FrontendNetwork
}

# Start the containers
Write-Host "Starting containers..." -ForegroundColor Yellow
Set-Location -Path $openemrTargetDir
docker-compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to start Docker containers. Check Docker logs for details." -ForegroundColor Red
} else {
    Write-Host "Docker containers started successfully." -ForegroundColor Green
}

# Configure Nginx Proxy Manager
Write-Host "Configuring Nginx Proxy Manager..." -ForegroundColor Yellow
$configureNpmScript = Join-Path -Path $PSScriptRoot -ChildPath "configure-npm.ps1"
if (Test-Path -Path $configureNpmScript -PathType Leaf) {
    & "$configureNpmScript" -Environment $Environment -Project "official" -Force:$Force
} else {
    Write-Host "configure-npm.ps1 script not found. Skipping Nginx Proxy Manager configuration." -ForegroundColor Yellow
}

Write-Host "Official OpenEMR setup complete!" -ForegroundColor Cyan
Write-Host "You can access OpenEMR at https://$($envConfig.Domains.openemr)" -ForegroundColor Cyan
Write-Host "Don't forget to add $($envConfig.Domains.openemr) to your hosts file if needed." -ForegroundColor Yellow 