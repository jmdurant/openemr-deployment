# Source Repository Management Script for AIOTP
# This script clones or updates the source repositories

param (
    [string]$Project = "aiotp",
    [string]$OpenEMRRepoUrl = "",
    [string]$TelehealthRepoUrl = "",
    [string]$OpenEMRBranch = "master",
    [string]$TelehealthBranch = "master",
    [switch]$Force = $false
)

# Load environment configuration to get repository URLs
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment "dev" -Project $Project
if (-not $envConfig) {
    Write-Host "Failed to load environment configuration" -ForegroundColor Red
    exit 1
}

# Define source repository directory
$sourceDir = "$PSScriptRoot\source-repos"

# If repo URLs not provided, use the ones from environment config
if ([string]::IsNullOrEmpty($OpenEMRRepoUrl)) {
    # Get repository URLs based on project
    $OpenEMRRepoUrl = $envConfig.RepositorySources.openemr
    
    # For the "official" project, skip the telehealth repository
    if ($Project -eq "official") {
        $TelehealthRepoUrl = ""
        Write-Host "Official project detected - skipping telehealth repository" -ForegroundColor Yellow
    } else {
        $TelehealthRepoUrl = $envConfig.RepositorySources.telehealth
    }
    
    Write-Host "Using repository URLs for project: $Project" -ForegroundColor Cyan
    Write-Host "OpenEMR: $OpenEMRRepoUrl" -ForegroundColor Cyan
    if (-not [string]::IsNullOrEmpty($TelehealthRepoUrl)) {
        Write-Host "Telehealth: $TelehealthRepoUrl" -ForegroundColor Cyan
    }
}

# Define repo directories based on URLs
$openemrRepoName = $OpenEMRRepoUrl.Split('/')[-1].Replace(".git", "")
$telehealthRepoName = ""
if (-not [string]::IsNullOrEmpty($TelehealthRepoUrl)) {
    $telehealthRepoName = $TelehealthRepoUrl.Split('/')[-1].Replace(".git", "")
}

$openemrSourceDir = "$sourceDir\$openemrRepoName"
$telehealthSourceDir = ""
if (-not [string]::IsNullOrEmpty($telehealthRepoName)) {
    $telehealthSourceDir = "$sourceDir\$telehealthRepoName"
}

# Create source directory if it doesn't exist
if (-not (Test-Path $sourceDir)) {
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    Write-Host "Created source repository directory: $sourceDir" -ForegroundColor Green
}

# Function to clone or update a repository
function Update-Repository {
    param (
        [string]$RepoUrl,
        [string]$Branch,
        [string]$TargetDir,
        [string]$RepoName
    )
    
    # Skip if repo URL is empty
    if ([string]::IsNullOrEmpty($RepoUrl)) {
        Write-Host "Skipping $RepoName repository (URL not provided)" -ForegroundColor Yellow
        return $true
    }
    
    if (Test-Path "$TargetDir\.git") {
        # Repository exists, update it
        Write-Host "Updating $RepoName repository..." -ForegroundColor Yellow
        Push-Location $TargetDir
        
        # Check if there are local changes
        $status = git status --porcelain
        if ($status) {
            Write-Host "Local changes detected in $RepoName repository. These will be discarded to maintain source integrity." -ForegroundColor Yellow
        }
        
        # Always force update to maintain source integrity
        Write-Host "Resetting $RepoName to match remote repository..." -ForegroundColor Yellow
        
        # Fetch the latest changes
        git fetch origin
        
        # Reset to the specified branch
        git reset --hard "origin/$Branch"
        git checkout $Branch
        git pull origin $Branch
        
        Pop-Location
        Write-Host "$RepoName repository reset and updated successfully." -ForegroundColor Green
        return $true
    } else {
        # Repository doesn't exist, clone it
        Write-Host "Cloning $RepoName repository..." -ForegroundColor Yellow
        git clone --branch $Branch $RepoUrl $TargetDir
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to clone $RepoName repository." -ForegroundColor Red
            return $false
        }
        
        Write-Host "$RepoName repository cloned successfully." -ForegroundColor Green
        return $true
    }
}

# Update OpenEMR repository
$openemrSuccess = Update-Repository -RepoUrl $OpenEMRRepoUrl -Branch $OpenEMRBranch -TargetDir $openemrSourceDir -RepoName "OpenEMR"

# Update Telehealth repository if URL is provided
$telehealthSuccess = $true
if (-not [string]::IsNullOrEmpty($TelehealthRepoUrl)) {
    $telehealthSuccess = Update-Repository -RepoUrl $TelehealthRepoUrl -Branch $TelehealthBranch -TargetDir $telehealthSourceDir -RepoName "Telehealth"
} else {
    Write-Host "Telehealth repository URL not provided. Skipping." -ForegroundColor Yellow
}

# Return results
if ($openemrSuccess -and $telehealthSuccess) {
    Write-Host "All source repositories updated successfully." -ForegroundColor Green
    return @{
        OpenEMRSourceDir = $openemrSourceDir
        TelehealthSourceDir = $telehealthSourceDir
        Success = $true
    }
} else {
    Write-Host "Failed to update one or more source repositories." -ForegroundColor Red
    return @{
        OpenEMRSourceDir = $openemrSourceDir
        TelehealthSourceDir = $telehealthSourceDir
        Success = $false
    }
}
