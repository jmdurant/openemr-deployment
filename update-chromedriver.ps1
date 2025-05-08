# Update ChromeDriver Script
# This script automatically detects Chrome version and downloads the matching ChromeDriver

# Parameters
param (
    [string]$DownloadDirectory = "$PSScriptRoot\selenium_packages",
    [switch]$Force = $false
)

Write-Host "ChromeDriver Auto-Update Tool" -ForegroundColor Cyan
Write-Host "-----------------------------" -ForegroundColor Cyan

# Create download directory if it doesn't exist
if (-not (Test-Path $DownloadDirectory)) {
    Write-Host "Creating download directory: $DownloadDirectory" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
}

# Get current Chrome version
try {
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) {
        # Try alternative locations
        $chromePath = (Get-Item (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe').'(Default)' -ErrorAction SilentlyContinue).FullName
    }

    if (-not $chromePath -or -not (Test-Path $chromePath)) {
        throw "Chrome executable not found. Please ensure Chrome is installed."
    }

    $chromeVersion = (Get-Item $chromePath).VersionInfo.ProductVersion
    Write-Host "Detected Chrome version: $chromeVersion" -ForegroundColor Green
} catch {
    Write-Host "Error detecting Chrome version: $_" -ForegroundColor Red
    exit 1
}

# Check if we already have this version (unless Force is used)
$chromeDriverPath = Join-Path $DownloadDirectory "chromedriver.exe"
if ((-not $Force) -and (Test-Path $chromeDriverPath)) {
    try {
        $currentDriverVersion = & $chromeDriverPath --version
        if ($currentDriverVersion -match $chromeVersion) {
            Write-Host "ChromeDriver $chromeVersion is already installed. Use -Force to reinstall." -ForegroundColor Green
            exit 0
        } else {
            Write-Host "Current ChromeDriver version ($currentDriverVersion) doesn't match Chrome version ($chromeVersion)." -ForegroundColor Yellow
            Write-Host "Proceeding with update..." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Couldn't determine current ChromeDriver version. Proceeding with download." -ForegroundColor Yellow
    }
}

# Get the matching ChromeDriver version from Chrome for Testing JSON API
Write-Host "Looking up matching ChromeDriver version..." -ForegroundColor Cyan

try {
    # First try to find exact version match
    $knownVersionsUrl = "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json"
    $response = Invoke-WebRequest -Uri $knownVersionsUrl -UseBasicParsing | ConvertFrom-Json
    
    # First look for exact match in versions array
    $exactMatch = $response.versions | Where-Object { $_.version -eq $chromeVersion }
    
    if ($exactMatch) {
        Write-Host "Found exact matching version!" -ForegroundColor Green
        $downloadUrl = ($exactMatch.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).url
    } else {
        # If no exact match, check in channels section (stable, beta, dev, canary)
        Write-Host "No exact match found, checking latest stable channel version..." -ForegroundColor Yellow
        
        # Alternative URL that shows the latest versions per channel
        $channelsUrl = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json"
        $channelsResponse = Invoke-WebRequest -Uri $channelsUrl -UseBasicParsing | ConvertFrom-Json
        
        # Extract major version from detected Chrome
        $majorVersion = $chromeVersion.Split('.')[0]
        
        # Get stable channel version and check if major version matches
        $stableVersion = $channelsResponse.channels.stable.version
        $stableMajor = $stableVersion.Split('.')[0]
        
        if ($majorVersion -eq $stableMajor) {
            Write-Host "Using latest stable version $stableVersion (same major version as installed Chrome)" -ForegroundColor Yellow
            $downloadUrl = ($channelsResponse.channels.stable.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).url
        } else {
            # As a fallback, use specific version lookup
            Write-Host "No matching stable version found, searching for closest version..." -ForegroundColor Yellow
            
            # Find all versions with the same major version
            $matchingMajorVersions = $response.versions | Where-Object { $_.version.StartsWith("$majorVersion.") }
            
            if ($matchingMajorVersions) {
                # Sort by version and take the latest
                $latestMatchingVersion = $matchingMajorVersions | Sort-Object -Property { [version]$_.version } -Descending | Select-Object -First 1
                Write-Host "Found closest version: $($latestMatchingVersion.version)" -ForegroundColor Yellow
                $downloadUrl = ($latestMatchingVersion.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).url
            } else {
                throw "No compatible ChromeDriver version found for Chrome $chromeVersion"
            }
        }
    }
    
    # Download ChromeDriver
    if ($downloadUrl) {
        $zipFile = Join-Path $DownloadDirectory "chromedriver-win64.zip"
        Write-Host "Downloading ChromeDriver from: $downloadUrl" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile
        
        # Extract the zip file
        Write-Host "Extracting ChromeDriver..." -ForegroundColor Cyan
        Expand-Archive -Path $zipFile -DestinationPath $DownloadDirectory -Force
        
        # Copy chromedriver.exe to the correct location
        $extractedDriverPath = Join-Path $DownloadDirectory "chromedriver-win64\chromedriver.exe"
        if (Test-Path $extractedDriverPath) {
            # Kill any running chromedriver processes first
            Get-Process -Name "chromedriver" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 1
            
            # Copy to download directory root
            Copy-Item -Path $extractedDriverPath -Destination $chromeDriverPath -Force
            
            # Also copy to script root if different from download directory
            if ($PSScriptRoot -ne $DownloadDirectory) {
                Copy-Item -Path $extractedDriverPath -Destination (Join-Path $PSScriptRoot "chromedriver.exe") -Force
            }
            
            # Verify new chromedriver version
            try {
                $newVersion = & $chromeDriverPath --version
                Write-Host "Successfully installed ChromeDriver: $newVersion" -ForegroundColor Green
            } catch {
                Write-Host "ChromeDriver was installed but version check failed." -ForegroundColor Yellow
            }
        } else {
            Write-Host "Error: ChromeDriver executable not found in extracted zip." -ForegroundColor Red
            exit 1
        }
    } else {
        throw "Failed to find download URL for ChromeDriver."
    }
} catch {
    Write-Host "Error downloading or installing ChromeDriver: $_" -ForegroundColor Red
    exit 1
}

Write-Host "ChromeDriver update completed successfully!" -ForegroundColor Green 