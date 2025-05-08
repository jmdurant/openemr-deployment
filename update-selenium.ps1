# Update Selenium WebDriver and ChromeDriver Script
# This script automates the installation and updating of Selenium WebDriver and ChromeDriver

param (
    [switch]$Force = $false,
    [string]$SeleniumVersion = "4.18.1"
)

$ErrorActionPreference = "Stop"
$seleniumPath = Join-Path $PSScriptRoot "selenium_packages"

Write-Host "Selenium WebDriver and ChromeDriver Update Tool" -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Cyan

# Create directory if it doesn't exist
if (-not (Test-Path $seleniumPath)) {
    Write-Host "Creating selenium packages directory: $seleniumPath" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $seleniumPath -Force | Out-Null
}

# Step 1: Check and install NuGet Selenium WebDriver and Support packages
Write-Host "`nStep 1: Installing/Updating Selenium WebDriver and Support packages..." -ForegroundColor Cyan

# First, ensure NuGet is available
$nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
if (-not $nugetProvider) {
    Write-Host "Installing NuGet package provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
}

# Check if required packages are already installed
$webDriverPath = Join-Path $seleniumPath "Selenium.WebDriver.$SeleniumVersion"
$supportPath = Join-Path $seleniumPath "Selenium.Support.$SeleniumVersion"

$installWebDriver = $Force -or (-not (Test-Path $webDriverPath))
$installSupport = $Force -or (-not (Test-Path $supportPath))

try {
    # Change to the selenium_packages directory
    Push-Location $seleniumPath
    
    # Install/update Selenium.WebDriver
    if ($installWebDriver) {
        Write-Host "Installing Selenium.WebDriver version $SeleniumVersion..." -ForegroundColor Yellow
        
        # Download NuGet package directly
        $webDriverUrl = "https://www.nuget.org/api/v2/package/Selenium.WebDriver/$SeleniumVersion"
        $webDriverNupkg = Join-Path $seleniumPath "Selenium.WebDriver.$SeleniumVersion.nupkg"
        
        Invoke-WebRequest -Uri $webDriverUrl -OutFile $webDriverNupkg
        
        # Extract the package
        if (Test-Path $webDriverPath) {
            Remove-Item $webDriverPath -Recurse -Force
        }
        
        # Rename nupkg to zip for extraction
        $webDriverZip = $webDriverNupkg -replace '\.nupkg$', '.zip'
        Copy-Item $webDriverNupkg $webDriverZip -Force
        
        # Extract
        Expand-Archive -Path $webDriverZip -DestinationPath $webDriverPath -Force
        
        # Cleanup
        Remove-Item $webDriverNupkg -Force
        Remove-Item $webDriverZip -Force
        
        Write-Host "Selenium.WebDriver $SeleniumVersion installed successfully" -ForegroundColor Green
    } else {
        Write-Host "Selenium.WebDriver $SeleniumVersion is already installed" -ForegroundColor Green
    }
    
    # Install/update Selenium.Support
    if ($installSupport) {
        Write-Host "Installing Selenium.Support version $SeleniumVersion..." -ForegroundColor Yellow
        
        # Download NuGet package directly
        $supportUrl = "https://www.nuget.org/api/v2/package/Selenium.Support/$SeleniumVersion"
        $supportNupkg = Join-Path $seleniumPath "Selenium.Support.$SeleniumVersion.nupkg"
        
        Invoke-WebRequest -Uri $supportUrl -OutFile $supportNupkg
        
        # Extract the package
        if (Test-Path $supportPath) {
            Remove-Item $supportPath -Recurse -Force
        }
        
        # Rename nupkg to zip for extraction
        $supportZip = $supportNupkg -replace '\.nupkg$', '.zip'
        Copy-Item $supportNupkg $supportZip -Force
        
        # Extract
        Expand-Archive -Path $supportZip -DestinationPath $supportPath -Force
        
        # Cleanup
        Remove-Item $supportNupkg -Force
        Remove-Item $supportZip -Force
        
        Write-Host "Selenium.Support $SeleniumVersion installed successfully" -ForegroundColor Green
    } else {
        Write-Host "Selenium.Support $SeleniumVersion is already installed" -ForegroundColor Green
    }
}
finally {
    # Restore original location
    Pop-Location
}

# Step 2: Update ChromeDriver
Write-Host "`nStep 2: Updating ChromeDriver to match Chrome browser version..." -ForegroundColor Cyan

# Call update-chromedriver.ps1
$updateChromeDriverScript = Join-Path $PSScriptRoot "update-chromedriver.ps1"
if (Test-Path $updateChromeDriverScript) {
    Write-Host "Running ChromeDriver update script..." -ForegroundColor Yellow
    & $updateChromeDriverScript -DownloadDirectory $seleniumPath -Force:$Force
} else {
    Write-Host "ChromeDriver update script not found at: $updateChromeDriverScript" -ForegroundColor Red
    Write-Host "Please ensure update-chromedriver.ps1 is in the same directory as this script" -ForegroundColor Yellow
}

Write-Host "`nSelenium WebDriver and ChromeDriver update completed successfully!" -ForegroundColor Green
Write-Host "Selenium WebDriver version: $SeleniumVersion" -ForegroundColor Green

# Check the ChromeDriver version
$chromeDriverPath = Join-Path $seleniumPath "chromedriver.exe"
if (Test-Path $chromeDriverPath) {
    $chromeDriverVersion = & $chromeDriverPath --version
    if ($chromeDriverVersion) {
        Write-Host "ChromeDriver version: $chromeDriverVersion" -ForegroundColor Green
    }
}

Write-Host "`nYou can now use Selenium WebDriver in your scripts!" -ForegroundColor Green 