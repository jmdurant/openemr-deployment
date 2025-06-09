param(
    [string]$Environment,
    [string]$ProjectName,
    [string]$DomainBase,
    [string]$OutputPath = "$PSScriptRoot\start-deployment.sh"
)

# Find the most recent deployment zip if parameters aren't all specified
if (-not $Environment -or -not $ProjectName -or -not $DomainBase) {
    Write-Host "Finding most recent deployment zip..." -ForegroundColor Cyan
    
    # Find all zip files that match our naming pattern
    $deploymentZips = Get-ChildItem -Path $PSScriptRoot -Filter "*.zip" | 
                      Where-Object { $_.Name -match "^(.+?)-([^-]+)-(\d{8}-\d{6})\.zip$" } |
                      Sort-Object LastWriteTime -Descending
    
    if ($deploymentZips.Count -gt 0) {
        $latestZip = $deploymentZips[0]
        Write-Host "Found most recent deployment: $($latestZip.Name)" -ForegroundColor Green
        
        # Extract information from the filename
        # Handle the case where ProjectName might already include Environment
        # Format could be either:
        # - ProjectName-Environment-timestamp.zip (e.g., official-production-20250519-091255.zip)
        # - ProjectName-Environment-Environment-timestamp.zip (e.g., official-production-production-20250519-091255.zip)
        
        if ($latestZip.Name -match "^(.+?)-([^-]+)-(\d{8}-\d{6})\.zip$") {
            $fullProjectName = $matches[1]
            $extractedEnvironment = $matches[2]
            
            # Check if ProjectName already includes Environment
            if ($fullProjectName -match "^([^-]+)-([^-]+)$") {
                # ProjectName includes Environment (e.g., official-production)
                $extractedProjectName = $matches[1]
                $extractedEnvironment = $matches[2] # Override with the environment from ProjectName
            } else {
                # ProjectName doesn't include Environment
                $extractedProjectName = $fullProjectName
            }
            
            # Only override parameters that weren't explicitly provided
            if (-not $ProjectName) {
                $ProjectName = $extractedProjectName
                Write-Host "Using Project: $ProjectName from zip filename" -ForegroundColor Cyan
            }
            
            if (-not $Environment) {
                $Environment = $extractedEnvironment
                Write-Host "Using Environment: $Environment from zip filename" -ForegroundColor Cyan
            }
            
            # For DomainBase, we need to look at the setup.ps1 history or use a default
            if (-not $DomainBase) {
                # Try to find the last used domain base from setup.ps1 history
                # For now, use a default value
                $DomainBase = "localhost"
                Write-Host "Using default DomainBase: $DomainBase (specify -DomainBase to override)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "No previous deployment zips found. Please specify all parameters." -ForegroundColor Yellow
    }
}

# Ensure all required parameters are set
if (-not $Environment -or -not $ProjectName -or -not $DomainBase) {
    Write-Host "Missing required parameters. Please specify:" -ForegroundColor Red
    if (-not $Environment) { Write-Host "  -Environment" -ForegroundColor Red }
    if (-not $ProjectName) { Write-Host "  -ProjectName" -ForegroundColor Red }
    if (-not $DomainBase) { Write-Host "  -DomainBase" -ForegroundColor Red }
    exit 1
}

# Load environment configuration
Write-Host "Loading environment configuration..." -ForegroundColor Yellow
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $ProjectName -DomainBase $DomainBase

# Read the template script
$startupScriptSource = Join-Path $PSScriptRoot "templates\start-deployment.sh"
if (-not (Test-Path $startupScriptSource)) {
    Write-Host "Error: Template script not found at $startupScriptSource" -ForegroundColor Red
    exit 1
}

$content = Get-Content -Path $startupScriptSource -Raw

# Replace placeholder variables with actual values
Write-Host "Customizing startup script for deployment..." -ForegroundColor Green
$content = $content -replace "__DOMAIN_BASE__", $DomainBase
$content = $content -replace "__PROJECT_NAME__", $ProjectName
$content = $content -replace "__ENVIRONMENT__", $Environment
$content = $content -replace "__NPM_ADMIN_PORT__", $envConfig.NpmPorts.admin
$content = $content -replace "__NPM_HTTP_PORT__", $envConfig.NpmPorts.http
$content = $content -replace "__NPM_HTTPS_PORT__", $envConfig.NpmPorts.https

# Ensure the script has Unix-style line endings (LF instead of CRLF)
$content = $content -replace "`r`n", "`n"

# Write the customized content to the destination file
[System.IO.File]::WriteAllText($OutputPath, $content)

Write-Host "Deployment script prepared at: $OutputPath" -ForegroundColor Green
Write-Host "Parameters used:" -ForegroundColor Cyan
Write-Host "  Project: $ProjectName" -ForegroundColor Cyan
Write-Host "  Environment: $Environment" -ForegroundColor Cyan
Write-Host "  Domain Base: $DomainBase" -ForegroundColor Cyan
Write-Host "  NPM Admin Port: $($envConfig.NpmPorts.admin)" -ForegroundColor Cyan
Write-Host "  NPM HTTP Port: $($envConfig.NpmPorts.http)" -ForegroundColor Cyan
Write-Host "  NPM HTTPS Port: $($envConfig.NpmPorts.https)" -ForegroundColor Cyan
Write-Host ""
Write-Host "You can now transfer this file to your target server." -ForegroundColor Yellow
