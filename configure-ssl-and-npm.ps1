# Script to configure SSL certificates and Nginx Proxy Manager
param (
    [string]$Environment = "production",
    [string]$Project = "aiotp",
    [switch]$Force = $false,
    [string]$NPMPassword = "",
    [string]$DomainBase = "localhost",
    [string]$NpmUrl = "",
    [switch]$ReplaceCertificate = $false
)

# Get environment configuration
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project -DomainBase $DomainBase

# Set NPM URL based on environment configuration
if ([string]::IsNullOrEmpty($NpmUrl) -and $envConfig) {
    $NpmUrl = "http://localhost:$($envConfig.Config.npmPorts.admin)"
    Write-Host "Using environment-specific NPM URL: $NpmUrl" -ForegroundColor Green
} elseif ([string]::IsNullOrEmpty($NpmUrl)) {
    $NpmUrl = "http://localhost:81"
    Write-Host "Using default NPM URL: $NpmUrl" -ForegroundColor Yellow
}

# Step 1: Call selenium-ssl.ps1 to set up SSL certificates and get the certificate ID
Write-Host "Configuring SSL certificates using Selenium..." -ForegroundColor Cyan
$sslOutput = & "$PSScriptRoot\selenium-ssl.ps1" -Environment $Environment -NpmUrl $NpmUrl
$certificateId = $null

# Extract the certificate ID from the output
foreach ($line in $sslOutput) {
    Write-Host "SSL output: $line"
    if ($line -match "CERTIFICATE_ID=(\d+)") {
        $certificateId = $matches[1]
        Write-Host "Found Certificate ID: $certificateId" -ForegroundColor Green
        break
    }
}

# Step 2: Call configure-npm.ps1 with the certificate ID
Write-Host "Configuring Nginx Proxy Manager hosts..." -ForegroundColor Cyan
if ($certificateId) {
    Write-Host "Using Certificate ID: $certificateId" -ForegroundColor Green
    & "$PSScriptRoot\configure-npm.ps1" -Environment $Environment -Project $Project -NpmUrl $NpmUrl -Force:$Force -ReplaceCertificate:$ReplaceCertificate -certificate_id $certificateId
} else {
    Write-Host "No certificate ID found, configuring without specific certificate ID" -ForegroundColor Yellow
    & "$PSScriptRoot\configure-npm.ps1" -Environment $Environment -Project $Project -NpmUrl $NpmUrl -Force:$Force -ReplaceCertificate:$ReplaceCertificate
}

Write-Host "SSL certificate and NPM configuration complete!" -ForegroundColor Green 