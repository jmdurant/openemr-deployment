param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [Parameter(Mandatory=$true)]
    [string]$ProjectName
)

# Function definition copied from setup.ps1
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
    docker exec $containerPattern sed -i 's/\$config\s*=\s*1;/\$config = 0;/' /var/www/html/sites/default/sqlconf.php
    docker exec $containerPattern sed -i 's/\$config\s*=\s*0;/\$config = 0;/' /var/www/html/sites/default/sqlconf.php # Ensure it's 0 if it was already 0
    
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
    docker exec $containerPattern composer install --working-dir=/var/www/html --no-interaction --no-plugins --no-scripts --prefer-dist
    $composerExitCode = $LASTEXITCODE
    if ($composerExitCode -ne 0) {
        Write-Host "Error: Composer install failed with exit code $composerExitCode" -ForegroundColor Red
    } else {
        Write-Host "Composer install completed." -ForegroundColor Green
        # Optional: Ensure web server owns the files AFTER composer runs (may need www-data:www-data depending on container setup)
        Write-Host "Attempting to set vendor directory ownership for web server..." -ForegroundColor Cyan
        docker exec $containerPattern chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.lock
        $chownExitCode = $LASTEXITCODE
        if ($chownExitCode -ne 0) {
             Write-Host "Warning: Failed to set ownership on vendor directory (might be okay if running as root). Exit code: $chownExitCode" -ForegroundColor Yellow
        }
    }

    Write-Host "OpenEMR configuration process finished." -ForegroundColor Green
    Write-Host "You should now be able to access the setup page." -ForegroundColor Green
}

# Call the function with provided parameters
Configure-OpenEMR -Environment $Environment -ProjectName $ProjectName 