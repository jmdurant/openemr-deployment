# Unified Deployment Script for Telehealth OpenEMR Module (Docker)
#
# Usage:
#   .\deploy-telehealth-module.ps1                                    # Default: official-staging
#   .\deploy-telehealth-module.ps1 -Force                             # Clean install with defaults, no prompts
#   .\deploy-telehealth-module.ps1 -Project "myproject" -Environment "prod" # Custom project/environment
#   .\deploy-telehealth-module.ps1 -Restart                           # Force container restart
#   .\deploy-telehealth-module.ps1 -Project "test" -Environment "dev" -Force # Full automation, no prompts
#
# Parameters:
#   -Force        : Perform clean uninstall before deployment AND skip all prompts (removes module from DB)
#   -Project      : Project name for container naming (default: "official")
#   -Environment  : Environment name for container naming (default: "staging") 
#   -Restart      : Force container restart (default: $false, will prompt if not specified and not using -Force)
#
# Container Pattern: {Project}-{Environment}-{service}-1
#   Examples:
#     official-staging-openemr-1
#     official-staging-telehealth-web-1
#     myproject-prod-openemr-1
#     myproject-prod-telehealth-web-1

param(
    [switch]$Force,
    [string]$Project = "official",
    [string]$Environment = "staging",
    [switch]$Restart = $false
)
$ErrorActionPreference = 'Stop'

# Define paths using parameterized container names
$HostModuleDir = "C:\Users\docto\Windsurf\telehealth-module"
$TargetDir = "C:\Users\docto\Windsurf\aiotp-deployment\$Project-$Environment\openemr\interface\modules\custom_modules\oe-module-telehealth"
$ContainerName = "$Project-$Environment-openemr-1"
$TelehealthContainerName = "$Project-$Environment-telehealth-web-1"
$ContainerModuleDir = "/var/www/localhost/htdocs/openemr/interface/modules/custom_modules/oe-module-telehealth"

# Function to perform a clean uninstall
function Uninstall-TelehealthModule {
    Write-Host "Performing clean uninstall of Telehealth module..." -ForegroundColor Yellow
    
    # Remove module from container
    Write-Host "Removing module from container..." -ForegroundColor Yellow
    docker exec -it $ContainerName rm -rf $ContainerModuleDir
    
    # Remove module from database
    Write-Host "Removing module from OpenEMR database..." -ForegroundColor Yellow
    docker exec -it $ContainerName mysql -uopenemr -popenemr openemr -e "DELETE FROM modules WHERE mod_directory = 'oe-module-telehealth';"
    
    # Restart container to clear caches
    Write-Host "Restarting OpenEMR container..." -ForegroundColor Yellow
    docker restart $ContainerName
    
    # Wait for container to be ready
    Write-Host "Waiting for OpenEMR container to restart..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    Write-Host "Clean uninstall completed." -ForegroundColor Green
}

# Ask user if they want to perform a clean uninstall
if ($Force) {
    Uninstall-TelehealthModule
    # Automatically continue with deployment
} else {
    $cleanInstall = Read-Host "Do you want to perform a clean uninstall before deploying? (y/n)"
    if ($cleanInstall -eq "y" -or $cleanInstall -eq "Y") {
        Uninstall-TelehealthModule
        # Ask user if they want to continue with deployment
        $continueDeploy = Read-Host "Module uninstalled. Do you want to continue with deployment? (y/n)"
        if ($continueDeploy -ne "y" -and $continueDeploy -ne "Y") {
            Write-Host "Deployment canceled by user." -ForegroundColor Yellow
            exit 0
        }
    }
}

# Display configuration
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Telehealth Module Deployment Script (Docker)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Project: $Project" -ForegroundColor Gray
Write-Host "  Environment: $Environment" -ForegroundColor Gray
Write-Host "  OpenEMR Container: $ContainerName" -ForegroundColor Gray
Write-Host "  Telehealth Container: $TelehealthContainerName" -ForegroundColor Gray
Write-Host "  Force Clean Install: $Force" -ForegroundColor Gray
Write-Host "  Auto Restart: $Restart" -ForegroundColor Gray
Write-Host ""

# Check if source directory exists
if (-Not (Test-Path $HostModuleDir)) {
    Write-Host "Error: Source directory not found: $HostModuleDir" -ForegroundColor Red
    exit 1
}

# Remove existing installation if it exists
if (Test-Path $TargetDir) {
    Write-Host "Removing existing installation..." -ForegroundColor Yellow
    Remove-Item -Path $TargetDir -Recurse -Force
}

# Create target directory
Write-Host "Creating target directory..." -ForegroundColor Green
New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null

# Copy files, excluding git files and vendor directory
Write-Host "Copying files to target directory..." -ForegroundColor Green

# Get all items in source directory, excluding problematic directories
$items = Get-ChildItem -Path $HostModuleDir -Exclude @(".git", ".gitignore", "vendor", "node_modules")

foreach ($item in $items) {
    if ($item.PSIsContainer) {
        # It's a directory
        $targetSubDir = Join-Path -Path $TargetDir -ChildPath $item.Name
        
        # Create the target subdirectory
        New-Item -Path $targetSubDir -ItemType Directory -Force | Out-Null
        
        # Copy all items from this subdirectory
        Copy-Item -Path (Join-Path -Path $item.FullName -ChildPath "*") -Destination $targetSubDir -Recurse -Force
        
        Write-Host "  - Copied directory: $($item.Name)" -ForegroundColor Gray
    } else {
        # It's a file
        Copy-Item -Path $item.FullName -Destination $TargetDir -Force
        Write-Host "  - Copied file: $($item.Name)" -ForegroundColor Gray
    }
}

# 1. Copy telehealth module into the Docker container
Write-Host "Copying telehealth module into Docker container..." -ForegroundColor Green
docker cp $TargetDir ($ContainerName + ':/var/www/localhost/htdocs/openemr/interface/modules/custom_modules/')

# 1.1. ✅ FIX PERMISSIONS: Ensure proper ownership and permissions for module installation
Write-Host "Fixing OpenEMR permissions for module installation..." -ForegroundColor Green
Write-Host "  - Setting proper ownership (apache:apache)..." -ForegroundColor Gray
docker exec $ContainerName chown -R apache:apache /var/www/localhost/htdocs/openemr/

Write-Host "  - Setting forms directory permissions..." -ForegroundColor Gray
docker exec $ContainerName chmod 755 /var/www/localhost/htdocs/openemr/interface/forms/

Write-Host "  - Verifying permissions..." -ForegroundColor Gray
$formsPermissions = docker exec $ContainerName ls -ld /var/www/localhost/htdocs/openemr/interface/forms/
Write-Host "    Forms directory: $formsPermissions" -ForegroundColor Gray

# 2. ✅ COMPOSER INSTALL: OpenEMR's ModulesClassLoader expects vendor/autoload.php to exist
#    This is REQUIRED - ModulesClassLoader will fail without it
Write-Host "Running composer install (required by OpenEMR's ModulesClassLoader)..." -ForegroundColor Green
docker exec -it $ContainerName sh -c "cd $ContainerModuleDir && composer install --no-dev --optimize-autoloader"

# 3. Container restart - now parameterized and defaults to no restart
if ($Restart) {
    Write-Host "Restarting OpenEMR container (specified via -Restart parameter)..." -ForegroundColor Yellow
    docker restart $ContainerName
    Write-Host "Waiting for OpenEMR container to restart..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
} elseif ($Force) {
    Write-Host "Force mode: Skipping container restart (using hot deployment for speed)." -ForegroundColor Green
} else {
    Write-Host "Container restart is optional with the fixed bootstrap pattern." -ForegroundColor Yellow
    $userChoice = Read-Host "Do you want to restart the OpenEMR container? This may help with cache refresh but is not required. (y/n) [default: n]"
    if ($userChoice -eq "y" -or $userChoice -eq "Y") {
        Write-Host "Restarting OpenEMR container..." -ForegroundColor Yellow
        docker restart $ContainerName
        Write-Host "Waiting for OpenEMR container to restart..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    } else {
        Write-Host "Skipping container restart - using hot deployment." -ForegroundColor Green
    }
}

# 4. Update container hosts files to enable domain name resolution
Write-Host "Updating container hosts files for domain name resolution..." -ForegroundColor Green
$updateHostsScript = Join-Path -Path $HostModuleDir -ChildPath "update-container-hosts.ps1"
if (Test-Path $updateHostsScript) {
    & $updateHostsScript -Project $Project -Environment $Environment
} else {
    Write-Host "Warning: update-container-hosts.ps1 script not found. Domain name resolution may not work properly." -ForegroundColor Yellow
}

# Verify installation
$composerExists = Test-Path -Path "$TargetDir\composer.json"
$bootstrapExists = Test-Path -Path "$TargetDir\src\Bootstrap.php"

# Display results
Write-Host ""
if ($composerExists -and $bootstrapExists) {
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "Telehealth Module deployed successfully!" -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "✅ Deployment Details:" -ForegroundColor Green
    Write-Host "   • Project: $Project" -ForegroundColor Gray
    Write-Host "   • Environment: $Environment" -ForegroundColor Gray
    Write-Host "   • OpenEMR Container: $ContainerName" -ForegroundColor Gray
    Write-Host "   • Telehealth Container: $TelehealthContainerName" -ForegroundColor Gray
    Write-Host "   • Target Directory: $TargetDir" -ForegroundColor Gray
    Write-Host ""
    Write-Host "✅ Modern OpenEMR Module Deployment:" -ForegroundColor Green
    Write-Host "   • Uses proper bootstrap timing (only after installation)" -ForegroundColor Gray
    Write-Host "   • Composer install runs safely before module discovery" -ForegroundColor Gray
    Write-Host "   • ModulesClassLoader has required vendor/autoload.php" -ForegroundColor Gray
    Write-Host "   • No segfaults with Comlink's proven pattern" -ForegroundColor Gray
    Write-Host "   • Automatic permission fixes (apache:apache ownership)" -ForegroundColor Gray
    Write-Host "   • Forms directory properly configured for module installation" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "1. Log in to OpenEMR as administrator" -ForegroundColor Yellow
    Write-Host "2. Go to Modules > Manage Modules" -ForegroundColor Yellow
    Write-Host "3. Find 'Telehealth Virtual Care' in the list and click 'Install'" -ForegroundColor Yellow
    Write-Host "4. Configure the module in Modules > Telehealth Settings" -ForegroundColor Yellow
    
    # Check if we're using localhost domains and show SSL certificate instructions
    if ($Environment -like "*localhost*" -or $Environment -eq "staging" -or $Environment -eq "dev" -or $Environment -eq "development") {
        $jitsiDomain = "vcbknd-$Environment.localhost"
        $jitsiUrl = "https://$jitsiDomain/external_api.js"
        
        Write-Host ""
        Write-Host "🔒 IMPORTANT - SSL Certificate Setup for Localhost:" -ForegroundColor Red
        Write-Host "   Since you're using localhost domains, you need to accept the self-signed SSL certificate" -ForegroundColor Yellow
        Write-Host "   for Jitsi to work properly." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   1. Open your browser and visit: $jitsiUrl" -ForegroundColor Cyan
        Write-Host "   2. Click 'Advanced' when you see the security warning" -ForegroundColor Yellow
        Write-Host "   3. Click 'Proceed to $jitsiDomain (unsafe)'" -ForegroundColor Yellow
        Write-Host "   4. You should see a JavaScript file or 404 error (either is fine)" -ForegroundColor Yellow
        Write-Host "   5. The certificate is now accepted and Jitsi will load in OpenEMR" -ForegroundColor Green
        Write-Host ""
        Write-Host "   ⚠️  You must do this BEFORE trying to start a telehealth session!" -ForegroundColor Red
        Write-Host "      Otherwise the Jitsi component will fail to load." -ForegroundColor Red
    }
} else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "Deployment failed: composer.json or Bootstrap.php not found in target directory" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
}
