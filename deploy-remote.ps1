
# Simple Remote Deployment Script for All-In-One Telehealth Platform
# This script deploys the platform to a remote Linux server using SSH/SCP

param (
    [Parameter(Mandatory=$false)]
    [string]$Environment = "production",
    [string]$Project = "official",
    [string]$DomainBase = "vr2fit.com",
    [string]$RemoteServer = "129.158.220.120",
    [string]$RemoteUser = "ubuntu",
    [string]$KeyPath = "E:\Downloads\vr2fit_arm.ppk",
    [string]$RemoteDeployPath = "/home/ubuntu",
    [switch]$UseExistingZip,
    [switch]$Interactive,
    [switch]$Force,
    [switch]$StopContainers,
    [int]$Timeout = 60
)

Write-Host "===== SIMPLIFIED REMOTE DEPLOYMENT SCRIPT =====" -ForegroundColor Cyan
Write-Host "This script will copy the latest zip file to the server, extract it, and run start-deployment.sh" -ForegroundColor Cyan

# Interactive mode banner
if ($Interactive) {
    Write-Host "INTERACTIVE MODE ENABLED - Will prompt for confirmation before each step" -ForegroundColor Yellow
}

# Function to prompt for confirmation in interactive mode
function Confirm-Step {
    param (
        [string]$StepName
    )
    
    if ($Interactive) {
        $confirmation = Read-Host "Continue with step: $StepName? (y/n)"
        if ($confirmation -ne "y") {
            Write-Host "Step skipped or aborted by user." -ForegroundColor Yellow
            return $false
        }
    }
    return $true
}

# Check if PuTTY tools are available
try {
    $null = Get-Command plink -ErrorAction Stop
    $null = Get-Command pscp -ErrorAction Stop
} catch {
    Write-Host "PuTTY tools (plink/pscp) not found. Please install PuTTY and ensure it's in your PATH." -ForegroundColor Red
    Write-Host "You can download PuTTY from: https://www.putty.org/" -ForegroundColor Yellow
    exit 1
}

# Check if the key exists
if (-not (Test-Path $KeyPath)) {
    Write-Host "SSH key not found at $KeyPath" -ForegroundColor Red
    exit 1
}

# STEP 1: Find the latest deployment zip file
Write-Host "Finding latest deployment package..." -ForegroundColor Cyan

# Interactive: Show all available deployment packages
if ($Interactive) {
    Write-Host "Available deployment packages:" -ForegroundColor Gray
    Get-ChildItem -Path $PSScriptRoot -Filter "$Project-$Environment-*.zip" | Sort-Object LastWriteTime -Descending | Format-Table Name, LastWriteTime, Length -AutoSize
}

if (-not (Confirm-Step "Find latest deployment package")) {
    exit 0
}

$deploymentZips = Get-ChildItem -Path $PSScriptRoot -Filter "$Project-$Environment-*.zip" | Sort-Object LastWriteTime -Descending

if ($deploymentZips.Count -eq 0) {
    Write-Host "No deployment packages found. Please run backup-and-staging.ps1 first." -ForegroundColor Red
    exit 1
}

# Use the most recent zip file
$packagePath = $deploymentZips[0].FullName
$packageName = $deploymentZips[0].Name
Write-Host "Using deployment package: $packageName (created on $($deploymentZips[0].LastWriteTime))" -ForegroundColor Green

# STEP 2: Check if the zip file already exists on the remote server
Write-Host "Checking if deployment package already exists on remote server..." -ForegroundColor Cyan

if (-not (Confirm-Step "Check if deployment package exists on remote server")) {
    exit 0
}

# Enhanced debugging: List files on remote server
if ($Interactive) {
    Write-Host "Listing files on remote server in ${RemoteDeployPath}" -ForegroundColor Gray
    $listFilesCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""ls -la $RemoteDeployPath"""
    Write-Host "Running: $listFilesCmd" -ForegroundColor Gray
    $listFilesResult = Invoke-Expression $listFilesCmd
    Write-Host "Files on remote server:" -ForegroundColor Gray
    Write-Host $listFilesResult -ForegroundColor Gray
}

$checkFileCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""test -f $RemoteDeployPath/$packageName && echo 'exists' || echo 'not-exists'"""
Write-Host "Running: $checkFileCmd" -ForegroundColor Gray
$fileCheckResult = Invoke-Expression $checkFileCmd

# Debug output
Write-Host "File check result: '$fileCheckResult'" -ForegroundColor Gray

# Check if we should force upload regardless of existence
if ($Force) {
    Write-Host "Force parameter specified. Will copy file regardless of existence." -ForegroundColor Yellow
    $skipCopy = $false
} else {
    # Check if the file exists on the remote server
    # Trim the result to remove any whitespace or newlines
    $trimmedResult = $fileCheckResult.Trim()
    
    # Debug output of the exact trimmed result for troubleshooting
    Write-Host "Trimmed file check result: '$trimmedResult'" -ForegroundColor Gray
    
    if ($trimmedResult -eq "exists") {
        Write-Host "Deployment package already exists on remote server. Skipping copy." -ForegroundColor Green
        $skipCopy = $true
    } else {
        Write-Host "Deployment package does not exist on remote server. Will copy file." -ForegroundColor Yellow
        $skipCopy = $false
    }
}

# Copy the zip file if it doesn't exist on the remote server
if (-not $skipCopy) {
    Write-Host "Copying deployment package to remote server..." -ForegroundColor Cyan
    
    if (-not (Confirm-Step "Copy deployment package to remote server")) {
        Write-Host "Skipping file copy as requested." -ForegroundColor Yellow
        $skipCopy = $true
    } else {
        $pscpCmd = "pscp -i ""$KeyPath"" -batch ""$packagePath"" ${RemoteUser}@${RemoteServer}:$RemoteDeployPath/"
        Write-Host "Running: $pscpCmd" -ForegroundColor Gray
        $pscpProcess = Start-Process -FilePath "pscp" -ArgumentList @("-i", """$KeyPath""", "-batch", """$packagePath""", "${RemoteUser}@${RemoteServer}:$RemoteDeployPath/") -NoNewWindow -PassThru -Wait
        if ($pscpProcess.ExitCode -ne 0) {
            Write-Host "Failed to copy deployment package to remote server." -ForegroundColor Red
            exit 1
        }
    }
}

# Copy the simplified deployment script to the remote server
Write-Host "Copying simplified deployment script to remote server..." -ForegroundColor Cyan
$scriptPath = "$PSScriptRoot\start-deployment-simple.sh"
if (Test-Path $scriptPath) {
    $pscpScriptCmd = "pscp -i ""$KeyPath"" -batch ""$scriptPath"" ${RemoteUser}@${RemoteServer}:$RemoteDeployPath/"
    Write-Host "Running: $pscpScriptCmd" -ForegroundColor Gray
    $pscpScriptProcess = Start-Process -FilePath "pscp" -ArgumentList @("-i", """$KeyPath""", "-batch", """$scriptPath""", "${RemoteUser}@${RemoteServer}:$RemoteDeployPath/") -NoNewWindow -PassThru -Wait
    if ($pscpScriptProcess.ExitCode -ne 0) {
        Write-Host "Failed to copy deployment script to remote server." -ForegroundColor Yellow
        # Continue anyway, as the script might be in the zip file
    }
} else {
    Write-Host "Warning: Could not find start-deployment-simple.sh script locally." -ForegroundColor Yellow
}

# STEP 3: Check if the extracted folder already exists (only if we didn't copy a new file)
$projectDir = "$Project-$Environment"
$skipExtract = $false

# If we copied a new file, always extract it
if (-not $skipCopy) {
    Write-Host "New deployment package was copied. Will extract regardless of folder existence." -ForegroundColor Yellow
    $skipExtract = $false
} else {
    # Only check for folder existence if we didn't copy a new file
    Write-Host "Checking if extracted folder already exists..." -ForegroundColor Cyan

    if (-not (Confirm-Step "Check if extracted folder already exists")) {
        Write-Host "Skipping directory check as requested." -ForegroundColor Yellow
        exit 0
    }

    # Use a more reliable method to check directory existence
    # This runs a simple command that outputs the directory listing or "not-found" if it doesn't exist
    $checkDirCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""ls -la $RemoteDeployPath/$projectDir 2>/dev/null | head -1 || echo 'not-found'"""
    Write-Host "Running directory check: $checkDirCmd" -ForegroundColor Gray
    $dirCheckResult = Invoke-Expression $checkDirCmd

    # Debug output to see what we're getting back
    Write-Host "Directory check result: $dirCheckResult" -ForegroundColor Gray

    if ($dirCheckResult -and -not ($dirCheckResult -match "not-found")) {
        Write-Host "Extracted folder already exists on remote server." -ForegroundColor Green
        $skipExtract = $true
    } else {
        Write-Host "Extracted folder does not exist. Will extract zip file." -ForegroundColor Yellow
        $skipExtract = $false
    }
}

# STEP 4: Extract the zip file if needed and run the deployment script
Write-Host "Running deployment script..." -ForegroundColor Cyan

if (-not (Confirm-Step "Run deployment script")) {
    Write-Host "Skipping deployment script as requested." -ForegroundColor Yellow
    exit 0
}

# Build the command parameters to pass to the script
$scriptParams = "--project=$Project --environment=$Environment --domainbase=$DomainBase"

# Add stop parameter if requested
if ($StopContainers) {
    $scriptParams += " --stop"
    Write-Host "Will stop containers before deployment (-StopContainers specified)." -ForegroundColor Yellow
} else {
    Write-Host "Containers will NOT be stopped before deployment (default behavior)." -ForegroundColor Green
}

# Build the command to run the deployment script with the new extraction functionality
if ($skipExtract) {
    # If we're skipping extraction, just run the script in the existing directory
    $deployCmd = "cd $RemoteDeployPath/$projectDir && chmod +x ./start-deployment-simple.sh && sudo ./start-deployment-simple.sh $scriptParams"
    
    if ($Interactive) {
        Write-Host "Using existing directory. Will not extract zip file." -ForegroundColor Yellow
        Write-Host "Command to run: $deployCmd" -ForegroundColor Gray
    }
} else {
    # Use the new extraction functionality in start-deployment-simple.sh
    # This simplifies our command chain and makes it more reliable
    $deployCmd = "cd $RemoteDeployPath && chmod +x ./start-deployment-simple.sh && sudo ./start-deployment-simple.sh $scriptParams --zipfile=$packageName"
    
    if ($Interactive) {
        Write-Host "Will use start-deployment-simple.sh to extract zip file and run deployment." -ForegroundColor Yellow
        Write-Host "Command to run: $deployCmd" -ForegroundColor Gray
    }
}

$plinkCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""$deployCmd"""
Write-Host "Running: $plinkCmd" -ForegroundColor Gray

# Execute the command
Invoke-Expression $plinkCmd

# Check if the command succeeded
if ($LASTEXITCODE -ne 0) {
    Write-Host "Remote deployment FAILED. Please check the errors above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Remote deployment completed successfully!" -ForegroundColor Green
    Write-Host "You can access your deployment at: https://$DomainBase" -ForegroundColor Green
}

