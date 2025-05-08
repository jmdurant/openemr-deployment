# OpenEMR Configuration Script
# This script configures OpenEMR's database connection and other settings after container startup

param (
    [Parameter(Mandatory=$false)]
    [string]$Environment,
    [string]$Project = "aiotp",
    [switch]$InstallDependencies = $true
)

# If no environment is specified, show interactive selection
if (-not $Environment) {
    Write-Host "`nAvailable Environments:" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    
    # Load environment config to get available environments
    $envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment "production" -Project $Project
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
}

# Function to get user input with clear prompting
function Get-UserInput {
    param (
        [string]$Prompt,
        [string]$ForegroundColor = "Yellow",
        [string[]]$ValidResponses = @(),
        [string]$DefaultResponse = ""
    )
    
    # Always prompt
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

# Load environment configuration
Write-Host "Loading environment configuration for project: $Project, environment: $Environment" -ForegroundColor Yellow
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project

# OpenEMR configuration function
function Configure-OpenEMR {
    param (
        [string]$Environment,
        [string]$ProjectName,
        [switch]$InstallDependencies = $true
    )
    
    Write-Host "Configuring OpenEMR for environment: $Environment" -ForegroundColor Yellow
    
    # Try to find the OpenEMR container
    $containerPattern = "$ProjectName-openemr-openemr-1"
    $containerExists = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $containerPattern }
    
    if (-not $containerExists) {
        Write-Host "OpenEMR container not found. Please start the environment first." -ForegroundColor Yellow
        return
    }
    
    # Check if sqlconf.php exists in the container
    $sqlconfExistsCode = 0
    try {
        docker exec $containerPattern test -f /var/www/html/sites/default/sqlconf.php
        $sqlconfExistsCode = $LASTEXITCODE
    } catch {
        $sqlconfExistsCode = 1
    }
    
    if ($sqlconfExistsCode -ne 0) {
        Write-Host "Creating sqlconf.php file in OpenEMR container..." -ForegroundColor Yellow
        
        # Create sqlconf.php from the sample file
        docker exec $containerPattern bash -c "if [ -f /var/www/html/sites/default/sqlconf.sample.php ]; then cp /var/www/html/sites/default/sqlconf.sample.php /var/www/html/sites/default/sqlconf.php; fi"
        
        # Update database connection details
        docker exec $containerPattern sed -i 's/\$host.*;/\$host = "mysql";/' /var/www/html/sites/default/sqlconf.php
        docker exec $containerPattern sed -i 's/\$port.*;/\$port = "3306";/' /var/www/html/sites/default/sqlconf.php
        docker exec $containerPattern sed -i 's/\$login.*;/\$login = "openemr";/' /var/www/html/sites/default/sqlconf.php
        docker exec $containerPattern sed -i 's/\$pass.*;/\$pass = "openemr";/' /var/www/html/sites/default/sqlconf.php
        docker exec $containerPattern sed -i 's/\$dbase.*;/\$dbase = "openemr";/' /var/www/html/sites/default/sqlconf.php
        
        # Set the config variable to 1
        docker exec $containerPattern sed -i 's/\$config\s*=\s*0;/\$config = 1;/' /var/www/html/sites/default/sqlconf.php
        
        Write-Host "sqlconf.php created and configured in OpenEMR container" -ForegroundColor Green
        
        # Restart OpenEMR to apply changes
        Write-Host "Restarting OpenEMR container to apply changes..." -ForegroundColor Yellow
        docker restart $containerPattern
        Write-Host "OpenEMR container restarted" -ForegroundColor Green
    } else {
        Write-Host "sqlconf.php already exists in OpenEMR container. Checking configuration..." -ForegroundColor Yellow
        
        # Check the config variable
        $configValue = "0"
        try {
            $configValue = docker exec $containerPattern grep -o '\$config\s*=\s*[0-9]' /var/www/html/sites/default/sqlconf.php | grep -o '[0-9]'
        } catch {
            Write-Host "Could not determine \$config value. Will update it to be safe." -ForegroundColor Yellow
            $configValue = "0"
        }
        
        if ($configValue -eq "0") {
            Write-Host "Updating \$config value to 1..." -ForegroundColor Yellow
            docker exec $containerPattern sed -i 's/\$config\s*=\s*0;/\$config = 1;/' /var/www/html/sites/default/sqlconf.php
            
            # Restart OpenEMR to apply changes
            Write-Host "Restarting OpenEMR container to apply changes..." -ForegroundColor Yellow
            docker restart $containerPattern
            Write-Host "OpenEMR container restarted" -ForegroundColor Green
        } else {
            Write-Host "sqlconf.php is already configured (\$config = $configValue)" -ForegroundColor Green
        }
        
        # Check the host value
        $hostValue = ""
        try {
            $hostValue = docker exec $containerPattern grep -o '\$host\s*=\s*["'"'"'].*["'"'"']' /var/www/html/sites/default/sqlconf.php
        } catch {
            Write-Host "Could not determine \$host value. Will update it to be safe." -ForegroundColor Yellow
            $hostValue = "ops-openemr-mysql"
        }
        
        if ($hostValue -match "ops-openemr-mysql") {
            Write-Host "Updating \$host value to 'mysql'..." -ForegroundColor Yellow
            docker exec $containerPattern sed -i 's/\$host\s*=\s*["'"'"'].*["'"'"']/\$host = "mysql";/' /var/www/html/sites/default/sqlconf.php
            
            # Restart OpenEMR to apply changes
            Write-Host "Restarting OpenEMR container to apply changes..." -ForegroundColor Yellow
            docker restart $containerPattern
            Write-Host "OpenEMR container restarted" -ForegroundColor Green
        }
    }
    
    Write-Host "OpenEMR database configuration complete" -ForegroundColor Green
    
    # Optional dependency installation
    if ($InstallDependencies) {
        # Check if Composer dependencies are installed
        $vendorExistsCode = 0
        try {
            docker exec $containerPattern test -d /var/www/html/vendor
            $vendorExistsCode = $LASTEXITCODE
        } catch {
            $vendorExistsCode = 1
        }
        
        if ($vendorExistsCode -ne 0) {
            Write-Host "Composer dependencies not found. Installing..." -ForegroundColor Yellow
            docker exec $containerPattern composer install
            Write-Host "Composer dependencies installed" -ForegroundColor Green
        }
        
        # Check if Node dependencies are installed
        $nodeModulesExistsCode = 0
        try {
            docker exec $containerPattern test -d /var/www/html/node_modules
            $nodeModulesExistsCode = $LASTEXITCODE
        } catch {
            $nodeModulesExistsCode = 1
        }
        
        if ($nodeModulesExistsCode -ne 0) {
            Write-Host "Node dependencies not found. Installing..." -ForegroundColor Yellow
            docker exec $containerPattern npm install
            Write-Host "Node dependencies installed" -ForegroundColor Green
        }
    }
    
    # Get the HTTP port from environment config
    $httpPort = $envConfig.Config.containerPorts.openemr.http
    
    Write-Host "OpenEMR configuration complete!" -ForegroundColor Green
    Write-Host "OpenEMR is ready to use at: http://localhost:$httpPort/" -ForegroundColor Green
}

# Run the configuration function
Configure-OpenEMR -Environment $Environment -ProjectName $envConfig.ProjectName -InstallDependencies:$InstallDependencies

Write-Host "`nOpenEMR configuration completed!" -ForegroundColor Green
Write-Host "If you experience any issues, please check the Docker logs with:" -ForegroundColor Yellow
Write-Host "  docker logs $($envConfig.ProjectName)-openemr-openemr-1" -ForegroundColor Yellow


