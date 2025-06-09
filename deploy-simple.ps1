param (
    [string]$Environment = "production",
    [string]$Project = "official",
    [string]$DomainBase = "vr2fit.com",
    [string]$RemoteServer = "129.158.220.120",
    [string]$RemoteUser = "ubuntu",
    [string]$KeyPath = "E:\Downloads\vr2fit_arm.ppk"
)

# 1. Find the most recent zip file
$deploymentZips = Get-ChildItem -Path $PSScriptRoot -Filter "$Project-$Environment-*.zip" | Sort-Object LastWriteTime -Descending
if ($deploymentZips.Count -eq 0) {
    Write-Host "No deployment packages found. Please run backup-and-staging.ps1 first." -ForegroundColor Red
    exit 1
}

$packagePath = $deploymentZips[0].FullName
$packageName = $deploymentZips[0].Name
Write-Host "Using package: $packageName" -ForegroundColor Green

# 2. Test basic connectivity
Write-Host "Testing SSH connection..." -ForegroundColor Cyan
$testCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""echo 'Connection test successful'"""
try {
    $output = Invoke-Expression $testCmd
    if ($output -match "Connection test successful") {
        Write-Host "SSH connection successful" -ForegroundColor Green
    } else {
        Write-Host "SSH connection test failed" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "SSH connection failed: $_" -ForegroundColor Red
    exit 1
}

# 3. Create remote directory
Write-Host "Creating remote directory..." -ForegroundColor Cyan
$mkdirCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""mkdir -p /home/${RemoteUser}/aiotp-deployment"""
Invoke-Expression $mkdirCmd

# 4. Check if file already exists on remote server
Write-Host "Checking if package already exists on remote server..." -ForegroundColor Cyan
$checkCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""ls -la /home/${RemoteUser}/aiotp-deployment/$packageName 2>/dev/null || echo 'not-exists'"""
$result = Invoke-Expression $checkCmd

$copyFile = $true
if ($result -notmatch "not-exists") {
    Write-Host "Package already exists on remote server. Skipping copy." -ForegroundColor Yellow
    $copyFile = $false
    
    $copyAnyway = Read-Host "Do you want to copy it anyway? (y/n)"
    if ($copyAnyway -eq "y") {
        $copyFile = $true
    }
}

# 5. Copy the package if needed
if ($copyFile) {
    Write-Host "Copying package to remote server..." -ForegroundColor Cyan
    $copyCmd = "pscp -i ""$KeyPath"" -batch ""$packagePath"" ${RemoteUser}@${RemoteServer}:/home/${RemoteUser}/aiotp-deployment/"
    Write-Host "Running: $copyCmd" -ForegroundColor Gray
    Invoke-Expression $copyCmd
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to copy package to remote server" -ForegroundColor Red
        exit 1
    }
}

# 6. Extract the package
Write-Host "Extracting package on remote server..." -ForegroundColor Cyan
$extractCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""cd /home/${RemoteUser}/aiotp-deployment && unzip -o $packageName"""
Write-Host "Running: $extractCmd" -ForegroundColor Gray
Invoke-Expression $extractCmd

# 6.5. Check if Docker is installed
Write-Host "Checking if Docker is installed..." -ForegroundColor Cyan
$checkDockerCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""docker --version || echo 'Docker not installed'"""
$dockerResult = Invoke-Expression $checkDockerCmd

# If Docker is not installed, copy and run the Docker setup script
if ($dockerResult -match "Docker not installed") {
    Write-Host "Docker not installed. Setting up Docker..." -ForegroundColor Yellow
    
    # Copy the Docker setup script
    $dockerSetupPath = Join-Path $PSScriptRoot "docker-setup.sh"
    if (-not (Test-Path $dockerSetupPath)) {
        Write-Host "Creating Docker setup script..." -ForegroundColor Yellow
        Set-Content -Path $dockerSetupPath -Value (Get-Content -Path (Join-Path $PSScriptRoot "docker-setup.sh"))
    }
    
    $copyDockerCmd = "pscp -i ""$KeyPath"" -batch ""$dockerSetupPath"" ${RemoteUser}@${RemoteServer}:/home/${RemoteUser}/docker-setup.sh"
    Write-Host "Running: $copyDockerCmd" -ForegroundColor Gray
    Invoke-Expression $copyDockerCmd
    
    # Run the Docker setup script
    $runDockerSetupCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""chmod +x ./docker-setup.sh && sudo ./docker-setup.sh"""
    Write-Host "Running: $runDockerSetupCmd" -ForegroundColor Gray
    Invoke-Expression $runDockerSetupCmd
} else {
    Write-Host "Docker is already installed: $dockerResult" -ForegroundColor Green
}

# 7. Run the deployment script
Write-Host "Starting deployment..." -ForegroundColor Cyan
$projectDir = "$Project-$Environment"
$deployCmd = "plink -i ""$KeyPath"" -batch -ssh ${RemoteUser}@${RemoteServer} ""cd /home/${RemoteUser}/aiotp-deployment/$projectDir && chmod +x ./start-deployment.sh && sudo ./start-deployment.sh"""
Write-Host "Running: $deployCmd" -ForegroundColor Gray
Invoke-Expression $deployCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "Deployment completed successfully!" -ForegroundColor Green
    Write-Host "You can access your deployment at: https://$DomainBase" -ForegroundColor Green
} else {
    Write-Host "Deployment failed. Please check the errors above." -ForegroundColor Red
    Write-Host "You may need to run the deployment script manually:" -ForegroundColor Yellow
    Write-Host "  cd /home/${RemoteUser}/aiotp-deployment/$projectDir && chmod +x ./start-deployment.sh && sudo ./start-deployment.sh" -ForegroundColor Yellow
}
