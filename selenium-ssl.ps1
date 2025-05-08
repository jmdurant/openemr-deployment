# Selenium script for configuring SSL certificates in Nginx Proxy Manager
param (
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [Parameter(Mandatory=$true)]
    [string]$Project = "aiotp",
    [string]$NpmUrl = "",  # Remove default value, will be set from environment config
    [string]$DefaultEmail = "admin@example.com",
    [string]$DefaultPassword = "changeme",
    [string]$NewPassword = "your_secure_password",
    [switch]$ForceReinstall = $false,
    [switch]$Headless = $false  # Default to non-headless for development
)

# Load environment configuration
$envConfig = . "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project

Write-Host "Environment config loaded:" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor Cyan
Write-Host "Project: $Project" -ForegroundColor Cyan
Write-Host "Full config for environment:" -ForegroundColor Cyan
$envConfig | Format-Table -AutoSize

# If NpmUrl is not provided, construct it using the environment config
if ([string]::IsNullOrEmpty($NpmUrl)) {
    # Access the correct property path in the environment config
    $adminPort = $envConfig.NpmPorts.admin
    Write-Host "Raw admin port value: '$adminPort'" -ForegroundColor Cyan
    
    if ([string]::IsNullOrEmpty($adminPort)) {
        Write-Host "ERROR: NPM admin port is empty in environment config!" -ForegroundColor Red
        throw "NPM admin port not found in environment configuration"
    }
    
    Write-Host "Using NPM admin port from config: $adminPort" -ForegroundColor Cyan
    $NpmUrl = "http://localhost:$adminPort"
}

Write-Host "NPM URL set to: $NpmUrl" -ForegroundColor Green

# Set paths for Selenium packages
$seleniumPath = Join-Path $PSScriptRoot "selenium_packages"
$chromeDriverPath = Join-Path $seleniumPath "chromedriver.exe"
$webDriverDll = Join-Path $seleniumPath "Selenium.WebDriver.4.18.1\lib\netstandard2.0\WebDriver.dll"
$supportDll = Join-Path $seleniumPath "Selenium.Support.4.18.1\lib\netstandard2.0\WebDriver.Support.dll"

# Function to check if a file exists
function Test-FileExists {
    param($Path)
    return Test-Path $Path
}

# Function to load Selenium assemblies
function Load-SeleniumAssemblies {
    try {
        Write-Host "Loading Selenium assemblies..." -ForegroundColor Cyan
        
        # Check if DLLs exist
        if (-not (Test-FileExists $webDriverDll)) {
            throw "WebDriver.dll not found at: $webDriverDll"
        }
        if (-not (Test-FileExists $supportDll)) {
            throw "WebDriver.Support.dll not found at: $supportDll"
        }

        # Load assemblies
        Write-Host "Loading WebDriver.dll..." -ForegroundColor Cyan
        [System.Reflection.Assembly]::LoadFrom($webDriverDll) | Out-Null
        
        Write-Host "Loading WebDriver.Support.dll..." -ForegroundColor Cyan
        [System.Reflection.Assembly]::LoadFrom($supportDll) | Out-Null

        # Verify types are loaded
        $null = [OpenQA.Selenium.Chrome.ChromeDriver]
        $null = [OpenQA.Selenium.Chrome.ChromeOptions]
        $null = [OpenQA.Selenium.Support.UI.WebDriverWait]
        
        Write-Host "Selenium assemblies loaded successfully" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error loading Selenium assemblies: $_" -ForegroundColor Red
        Write-Host "Please ensure all required files are present in the selenium_packages folder" -ForegroundColor Yellow
        return $false
    }
}

# Function to wait for element
function Wait-ForElement {
    param(
        $Driver,
        $By,
        $Value,
        $Timeout = 10
    )
    try {
        Write-Host "Waiting for element: $By = $Value" -ForegroundColor Cyan
        $wait = New-Object OpenQA.Selenium.Support.UI.WebDriverWait($Driver, [TimeSpan]::FromSeconds($Timeout))
        $element = $wait.Until([OpenQA.Selenium.Support.UI.ExpectedConditions]::ElementExists([OpenQA.Selenium.By]::$By($Value)))
        if ($element) {
            Write-Host "Element found!" -ForegroundColor Green
        }
        return $element
    }
    catch {
        Write-Host "Timeout waiting for element ($By=$Value)" -ForegroundColor Red
        Write-Host "Current page source:" -ForegroundColor Yellow
        Write-Host $Driver.PageSource
        return $null
    }
}

# Function to wait for element to be clickable
function Wait-ForClickable {
    param(
        $Driver,
        $By,
        $Value,
        $Timeout = 10
    )
    try {
        Write-Host "Waiting for clickable element: $By = $Value" -ForegroundColor Cyan
        $wait = New-Object OpenQA.Selenium.Support.UI.WebDriverWait($Driver, [TimeSpan]::FromSeconds($Timeout))
        $element = $wait.Until([OpenQA.Selenium.Support.UI.ExpectedConditions]::ElementToBeClickable([OpenQA.Selenium.By]::$By($Value)))
        if ($element) {
            Write-Host "Clickable element found!" -ForegroundColor Green
        }
        return $element
    }
    catch {
        Write-Host "Timeout waiting for element to be clickable ($By=$Value)" -ForegroundColor Red
        Write-Host "Current page source:" -ForegroundColor Yellow
        Write-Host $Driver.PageSource
        return $null
    }
}

# Function to login to NPM
function Login-ToNPM {
    param(
        $Driver,
        $Email,
        $Password
    )
    try {
        Write-Host "Attempting to login to NPM..." -ForegroundColor Cyan
        
        # Wait for page load
        Write-Host "Waiting for page to load completely..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        
        Write-Host "Current URL: $($Driver.Url)" -ForegroundColor Cyan
        
        # Find and fill in email field
        Write-Host "Looking for email input field..." -ForegroundColor Cyan
        $emailInput = $Driver.FindElement([OpenQA.Selenium.By]::Name("identity"))
        Write-Host "Found email input, sending keys..." -ForegroundColor Cyan
        $emailInput.SendKeys($Email)
        
        # Find and fill in password field
        Write-Host "Looking for password input field..." -ForegroundColor Cyan
        $passwordInput = $Driver.FindElement([OpenQA.Selenium.By]::Name("secret"))
        Write-Host "Found password input, sending keys..." -ForegroundColor Cyan
        $passwordInput.SendKeys($Password)
        
        # Find and click login button
        Write-Host "Looking for login button..." -ForegroundColor Cyan
        $loginButton = $Driver.FindElement([OpenQA.Selenium.By]::CssSelector("button[type='submit']"))
        Write-Host "Found login button, clicking..." -ForegroundColor Cyan
        $loginButton.Click()
        
        # Wait for either the dashboard or the password change popup
        Write-Host "Waiting for page load after login..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2

        # Check for password change popup
        try {
            Write-Host "Checking for password change popup..." -ForegroundColor Cyan
            $cancelButton = $Driver.FindElement([OpenQA.Selenium.By]::XPath("//button[text()='Cancel']"))
            if ($cancelButton) {
                Write-Host "Found password change popup, clicking Cancel..." -ForegroundColor Cyan
                $cancelButton.Click()
                Write-Host "Waiting for popup to close and page to stabilize..." -ForegroundColor Cyan
                Start-Sleep -Seconds 3
            }
        }
        catch {
            Write-Host "No password change popup found, continuing..." -ForegroundColor Cyan
        }
        
        Write-Host "Successfully logged in to NPM" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Login failed: $_" -ForegroundColor Red
        Write-Host "Current URL: $($Driver.Url)" -ForegroundColor Yellow
        Write-Host "Page source:" -ForegroundColor Yellow
        Write-Host $Driver.PageSource
        return $false
    }
}

# Function to extract all certificate details from the table
function Get-CertificateDetails {
    param(
        $Driver
    )
    
    $certificateCount = 0
    $certificateIds = @()
    
    try {
        # Find the certificates table
        $certificatesTable = $Driver.FindElement([OpenQA.Selenium.By]::XPath("//table[contains(@class, 'table')]"))
        if ($certificatesTable) {
            Write-Host "Found certificates table, examining details..." -ForegroundColor Cyan
            
            # Get all data rows (exclude header row if present)
            $rows = $Driver.FindElements([OpenQA.Selenium.By]::XPath("//table//tr[td]"))
            $certificateCount = $rows.Count
            
            Write-Host "Found $certificateCount certificate rows in table" -ForegroundColor Cyan
            
            # Output all rows for debugging
            for ($i = 0; $i -lt $rows.Count; $i++) {
                try {
                    $rowText = $rows[$i].Text
                    Write-Host "Row $($i+1): $rowText" -ForegroundColor Cyan
                    
                    # Try to get the anchor elements in this row to find links
                    $links = $rows[$i].FindElements([OpenQA.Selenium.By]::TagName("a"))
                    if ($links.Count -gt 0) {
                        foreach ($link in $links) {
                            try {
                                $href = $link.GetAttribute("href")
                                $text = $link.Text
                                Write-Host "  Link: Text='$text', href='$href'" -ForegroundColor Cyan
                                
                                # If the link contains a certificate ID in the URL (nginx/certificates/X)
                                if ($href -match "/nginx/certificates/(\d+)") {
                                    $idFromUrl = $matches[1]
                                    Write-Host "  Found Certificate ID in URL: $idFromUrl" -ForegroundColor Green
                                    $certificateIds += $idFromUrl
                                }
                            } catch {
                                Write-Host "  Error getting link details: $_" -ForegroundColor Red
                            }
                        }
                    }
                    
                    # Try to get buttons or other elements with certificate actions
                    $buttons = $rows[$i].FindElements([OpenQA.Selenium.By]::TagName("button"))
                    if ($buttons.Count -gt 0) {
                        foreach ($button in $buttons) {
                            try {
                                $buttonText = $button.Text
                                $buttonClass = $button.GetAttribute("class")
                                $dataId = $button.GetAttribute("data-id")
                                Write-Host "  Button: Text='$buttonText', class='$buttonClass', data-id='$dataId'" -ForegroundColor Cyan
                                
                                if ($dataId -and $dataId -ne "") {
                                    Write-Host "  Found data ID in button: $dataId" -ForegroundColor Green
                                    if ($certificateIds -notcontains $dataId) {
                                        $certificateIds += $dataId
                                    }
                                }
                            } catch {
                                Write-Host "  Error getting button details: $_" -ForegroundColor Red
                            }
                        }
                    }
                } catch {
                    Write-Host "Error reading row $($i+1): $_" -ForegroundColor Red
                }
            }
            
            # Log all found IDs
            Write-Host "Total certificate IDs found: $($certificateIds.Count)" -ForegroundColor Cyan
            if ($certificateIds.Count -gt 0) {
                Write-Host "Certificate IDs: $($certificateIds -join ', ')" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "Error finding certificate table: $_" -ForegroundColor Red
    }
    
    return @{
        Count = $certificateCount
        Ids = $certificateIds
    }
}

# Original function for backward compatibility
function Get-CertificateCount {
    param(
        $Driver
    )
    
    $details = Get-CertificateDetails -Driver $Driver
    return $details.Count
}

# Function to configure SSL certificates
function Configure-SSLCertificates {
    param (
        [Parameter(Mandatory = $true)]
        $driver,
        [Parameter(Mandatory = $true)]
        $envConfig,
        [Parameter(Mandatory = $true)]
        [string]$Environment,
        [Parameter(Mandatory = $true)]
        [string]$DefaultEmail
    )
    
    try {
        Write-Host "Configuring SSL certificates..." -ForegroundColor Cyan
        $certificateId = $null

        # Navigate to SSL Certificates section
        Write-Host "Looking for SSL Certificates link..." -ForegroundColor Cyan
        $sslLink = $driver.FindElement([OpenQA.Selenium.By]::LinkText("SSL Certificates"))
        Write-Host "Found SSL Certificates link, clicking..." -ForegroundColor Cyan
        $sslLink.Click()
        Start-Sleep -Seconds 2
        
        # Get existing certificate details before adding a new one
        Write-Host "Getting existing certificate details..." -ForegroundColor Cyan
        $existingDetails = Get-CertificateDetails -Driver $driver
        Write-Host "Found $($existingDetails.Count) existing certificates" -ForegroundColor Cyan
        Write-Host "Existing certificate IDs: $($existingDetails.Ids -join ', ')" -ForegroundColor Cyan

        # Click the Add SSL Certificate dropdown button - it's a button, not a link
        Write-Host "Looking for Add SSL Certificate button..." -ForegroundColor Cyan
        $addButton = $driver.FindElement([OpenQA.Selenium.By]::XPath("//button[contains(text(), 'Add SSL Certificate')]"))
        Write-Host "Found Add SSL Certificate button, clicking..." -ForegroundColor Cyan
        $addButton.Click()
        Start-Sleep -Seconds 2
        
        # Add delay to ensure dropdown menu is fully visible
        Start-Sleep -Seconds 2
        
        # Now click the "Custom" option within the dropdown menu
        Write-Host "Looking for Custom option in dropdown menu..." -ForegroundColor Cyan
        $customOption = $driver.FindElement([OpenQA.Selenium.By]::XPath("//a[@data-cert='other' and contains(@class, 'dropdown-item')]"))
        Write-Host "Found Custom option, clicking..." -ForegroundColor Cyan
        $customOption.Click()

        # Add substantial delay to ensure the modal dialog fully loads
        Write-Host "Waiting for certificate options modal to load..." -ForegroundColor Cyan
        Start-Sleep -Seconds 5
        
        # Verify we're on the certificate selection screen by checking page state
        Write-Host "Verifying certificate selection screen is visible..." -ForegroundColor Cyan
        $wait = New-Object OpenQA.Selenium.Support.UI.WebDriverWait($driver, [TimeSpan]::FromSeconds(10))
        try {
            # First check if we can find the expected certificate selection section
            $modalTitle = $wait.Until([OpenQA.Selenium.Support.UI.ExpectedConditions]::ElementExists([OpenQA.Selenium.By]::XPath("//h5[contains(text(), 'Add Custom Certificate')]")))
            Write-Host "Certificate modal detected, continuing..." -ForegroundColor Green
        } catch {
            Write-Host "Certificate modal title not found, proceeding cautiously..." -ForegroundColor Yellow
        }
        
        # Optional debugging - only enable when troubleshooting specific issues
        # Write-Host "Current page source:" -ForegroundColor Yellow
        # Write-Host $driver.PageSource

        # Wait for the Custom certificate form to appear
        Write-Host "Waiting for Custom certificate form to load..." -ForegroundColor Cyan
        Start-Sleep -Seconds 5  # Increase wait time to ensure form is fully loaded

        # Debug: Output all input fields on the page
        Write-Host "DEBUG - Listing all input fields on the page:" -ForegroundColor Magenta
        $inputs = $driver.FindElements([OpenQA.Selenium.By]::TagName("input"))
        foreach ($input in $inputs) {
            try {
                $id = $input.GetAttribute("id")
                $name = $input.GetAttribute("name")
                $type = $input.GetAttribute("type")
                $placeholder = $input.GetAttribute("placeholder")
                Write-Host "Input: Id='$id', Name='$name', Type='$type', Placeholder='$placeholder'" -ForegroundColor Magenta
            } catch {
                Write-Host "Error getting input details: $_" -ForegroundColor Red
            }
        }

        # Fill in certificate details
        Write-Host "Filling in certificate details..." -ForegroundColor Cyan
        
        # Try multiple approaches to find the certificate name input
        $niceName = $null
        
        # Approach 1: Try by name attribute
        try {
            Write-Host "Trying to find certificate name input by name attribute..." -ForegroundColor Cyan
            $niceName = $driver.FindElement([OpenQA.Selenium.By]::Name("nice_name"))
            Write-Host "Found certificate name input by name attribute" -ForegroundColor Green
        } catch {
            Write-Host "Could not find certificate name input by name attribute" -ForegroundColor Yellow
        }
        
        # Approach 2: Try by ID attribute
        if (-not $niceName) {
            try {
                Write-Host "Trying to find certificate name input by ID attribute..." -ForegroundColor Cyan
                $niceName = $driver.FindElement([OpenQA.Selenium.By]::Id("nice_name"))
                Write-Host "Found certificate name input by ID attribute" -ForegroundColor Green
            } catch {
                Write-Host "Could not find certificate name input by ID attribute" -ForegroundColor Yellow
            }
        }
        
        # Approach 3: Try by placeholder attribute
        if (-not $niceName) {
            try {
                Write-Host "Trying to find certificate name input by placeholder attribute..." -ForegroundColor Cyan
                $niceName = $driver.FindElement([OpenQA.Selenium.By]::XPath("//input[contains(@placeholder, 'name') or contains(@placeholder, 'Name')]"))
                Write-Host "Found certificate name input by placeholder attribute" -ForegroundColor Green
            } catch {
                Write-Host "Could not find certificate name input by placeholder attribute" -ForegroundColor Yellow
            }
        }
        
        # Approach 4: Try by label text
        if (-not $niceName) {
            try {
                Write-Host "Trying to find certificate name input by label text..." -ForegroundColor Cyan
                $nameLabel = $driver.FindElement([OpenQA.Selenium.By]::XPath("//label[contains(text(), 'Name') or contains(text(), 'name')]"))
                if ($nameLabel) {
                    $forAttribute = $nameLabel.GetAttribute("for")
                    if ($forAttribute) {
                        $niceName = $driver.FindElement([OpenQA.Selenium.By]::Id($forAttribute))
                        Write-Host "Found certificate name input by label for attribute" -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host "Could not find certificate name input by label text" -ForegroundColor Yellow
            }
        }
        
        # Approach 5: Last resort, try any text input
        if (-not $niceName) {
            try {
                Write-Host "Last resort: trying to find first text input in the form..." -ForegroundColor Cyan
                $niceName = $driver.FindElement([OpenQA.Selenium.By]::XPath("//form//input[@type='text']"))
                Write-Host "Found potential certificate name input (first text input)" -ForegroundColor Green
            } catch {
                Write-Host "Could not find any text input field" -ForegroundColor Yellow
            }
        }
        
        if (-not $niceName) { 
            Write-Host "ERROR: Certificate name input not found using any method" -ForegroundColor Red
            throw "Certificate name input not found" 
        }
        
        # Set the certificate name
        $certificateName = "All-In-One Telehealth Platform - $Environment"
        Write-Host "Setting certificate name to: $certificateName" -ForegroundColor Cyan
        $niceName.Clear()  # Clear any existing value
        $niceName.SendKeys($certificateName)
        
        # For Custom certificates we need to upload cert files
        # Determine the certificate paths based on the environment
        $projectName = $envConfig.ProjectName
        Write-Host "Using project name from environment config: $projectName" -ForegroundColor Cyan
        
        # Use the correct path structure
        $certKeyFile = Join-Path $PSScriptRoot "$projectName\ssl\private.key"
        $certFile = Join-Path $PSScriptRoot "$projectName\ssl\certificate.crt"
        
        Write-Host "Current script directory: $PSScriptRoot" -ForegroundColor Cyan
        Write-Host "Certificate key path: $certKeyFile" -ForegroundColor Cyan
        Write-Host "Certificate file path: $certFile" -ForegroundColor Cyan
        
        # Check if certificate key file exists
        if (-not (Test-Path $certKeyFile)) {
            Write-Host "ERROR: Certificate key file not found at: $certKeyFile" -ForegroundColor Red
            throw "Certificate key file not found"
        }
        
        # Check if certificate file exists
        if (-not (Test-Path $certFile)) {
            Write-Host "ERROR: Certificate file not found at: $certFile" -ForegroundColor Red
            throw "Certificate file not found"
        }
        
        # Upload certificate key file
        Write-Host "Looking for certificate key input field..." -ForegroundColor Cyan
        $certKeyInput = $null
        
        # Try multiple approaches to find the certificate key input
        try {
            $certKeyInput = $driver.FindElement([OpenQA.Selenium.By]::Id("other_certificate_key"))
            Write-Host "Found certificate key input by ID" -ForegroundColor Green
        } catch {
            try {
                $certKeyInput = $driver.FindElement([OpenQA.Selenium.By]::XPath("//input[contains(@name, 'key') or contains(@id, 'key')][@type='file']"))
                Write-Host "Found certificate key input by XPath" -ForegroundColor Green
            } catch {
                try {
                    # Find by looking at labels
                    $keyLabel = $driver.FindElement([OpenQA.Selenium.By]::XPath("//label[contains(text(), 'Key') or contains(text(), 'key')]"))
                    if ($keyLabel) {
                        $forAttribute = $keyLabel.GetAttribute("for")
                        if ($forAttribute) {
                            $certKeyInput = $driver.FindElement([OpenQA.Selenium.By]::Id($forAttribute))
                            Write-Host "Found certificate key input by label for attribute" -ForegroundColor Green
                        }
                    }
                } catch {
                    # Last resort - find all file inputs and use the first one
                    $fileInputs = $driver.FindElements([OpenQA.Selenium.By]::XPath("//input[@type='file']"))
                    if ($fileInputs.Count -gt 0) {
                        $certKeyInput = $fileInputs[0]
                        Write-Host "Found certificate key input as first file input" -ForegroundColor Green
                    }
                }
            }
        }
        
        if (-not $certKeyInput) { 
            throw "Certificate key input not found" 
        }
        
        Write-Host "Uploading certificate key file..." -ForegroundColor Cyan
        $certKeyInput.SendKeys([System.IO.Path]::GetFullPath($certKeyFile))
        
        # Upload certificate file
        Write-Host "Looking for certificate input field..." -ForegroundColor Cyan
        $certInput = $null
        
        # Try multiple approaches to find the certificate input
        try {
            $certInput = $driver.FindElement([OpenQA.Selenium.By]::Id("other_certificate"))
            Write-Host "Found certificate input by ID" -ForegroundColor Green
        } catch {
            try {
                $certInput = $driver.FindElement([OpenQA.Selenium.By]::XPath("//input[contains(@name, 'cert') or contains(@id, 'cert')][@type='file']"))
                Write-Host "Found certificate input by XPath" -ForegroundColor Green
            } catch {
                try {
                    # Find by looking at labels
                    $certLabel = $driver.FindElement([OpenQA.Selenium.By]::XPath("//label[contains(text(), 'Certificate') or contains(text(), 'certificate')]"))
                    if ($certLabel) {
                        $forAttribute = $certLabel.GetAttribute("for")
                        if ($forAttribute) {
                            $certInput = $driver.FindElement([OpenQA.Selenium.By]::Id($forAttribute))
                            Write-Host "Found certificate input by label for attribute" -ForegroundColor Green
                        }
                    }
                } catch {
                    # Last resort - find all file inputs and use the second one (first one is key)
                    $fileInputs = $driver.FindElements([OpenQA.Selenium.By]::XPath("//input[@type='file']"))
                    if ($fileInputs.Count -gt 1) {
                        $certInput = $fileInputs[1]
                        Write-Host "Found certificate input as second file input" -ForegroundColor Green
                    }
                }
            }
        }
        
        if (-not $certInput) { 
            throw "Certificate input not found" 
        }
        
        Write-Host "Uploading certificate file..." -ForegroundColor Cyan
        $certInput.SendKeys([System.IO.Path]::GetFullPath($certFile))
        
        # Check if intermediate certificate should be uploaded (optional)
        $intermediateCertFile = Join-Path $PSScriptRoot "$projectName\ssl\chain.crt"
        if (Test-Path $intermediateCertFile) {
            Write-Host "Intermediate certificate found at: $intermediateCertFile" -ForegroundColor Cyan
            
            # Try multiple approaches to find the intermediate certificate input
            $intermediateCertInput = $null
            try {
                $intermediateCertInput = $driver.FindElement([OpenQA.Selenium.By]::Id("other_intermediate_certificate"))
                Write-Host "Found intermediate certificate input by ID" -ForegroundColor Green
            } catch {
                try {
                    $intermediateCertInput = $driver.FindElement([OpenQA.Selenium.By]::XPath("//input[contains(@name, 'intermediate') or contains(@id, 'intermediate')][@type='file']"))
                    Write-Host "Found intermediate certificate input by XPath" -ForegroundColor Green
                } catch {
                    try {
                        # Find by looking at labels
                        $intermediateLabel = $driver.FindElement([OpenQA.Selenium.By]::XPath("//label[contains(text(), 'Intermediate') or contains(text(), 'Chain')]"))
                        if ($intermediateLabel) {
                            $forAttribute = $intermediateLabel.GetAttribute("for")
                            if ($forAttribute) {
                                $intermediateCertInput = $driver.FindElement([OpenQA.Selenium.By]::Id($forAttribute))
                                Write-Host "Found intermediate certificate input by label for attribute" -ForegroundColor Green
                            }
                        }
                    } catch {
                        # Last resort - find all file inputs and use the third one (first is key, second is cert)
                        $fileInputs = $driver.FindElements([OpenQA.Selenium.By]::XPath("//input[@type='file']"))
                        if ($fileInputs.Count -gt 2) {
                            $intermediateCertInput = $fileInputs[2]
                            Write-Host "Found intermediate certificate input as third file input" -ForegroundColor Green
                        }
                    }
                }
            }
            
            if ($intermediateCertInput) {
                Write-Host "Uploading intermediate certificate file..." -ForegroundColor Cyan
                $intermediateCertInput.SendKeys([System.IO.Path]::GetFullPath($intermediateCertFile))
            } else {
                Write-Host "WARNING: Intermediate certificate input not found, skipping upload" -ForegroundColor Yellow
            }
        }
        
        # Wait a moment for the uploads to complete
        Write-Host "Waiting for uploads to complete..." -ForegroundColor Cyan
        Start-Sleep -Seconds 3
        
        # Click save button
        Write-Host "Looking for save button..." -ForegroundColor Cyan
        $saveButton = $null
        
        # Try multiple approaches to find the save button
        try {
            $saveButton = $driver.FindElement([OpenQA.Selenium.By]::XPath("//button[contains(@class, 'save') or contains(text(), 'Save')]"))
            Write-Host "Found save button by XPath (class or text)" -ForegroundColor Green
        } catch {
            try {
                $saveButton = $driver.FindElement([OpenQA.Selenium.By]::CssSelector("button.btn-primary"))
                Write-Host "Found save button by CSS selector (primary button)" -ForegroundColor Green
            } catch {
                try {
                    $saveButton = $driver.FindElement([OpenQA.Selenium.By]::XPath("//form//button[not(contains(@class, 'cancel') or contains(text(), 'Cancel'))]"))
                    Write-Host "Found save button by XPath (non-cancel button in form)" -ForegroundColor Green
                } catch {
                    # Last resort - find all buttons and use the first one that doesn't look like cancel/close
                    $buttons = $driver.FindElements([OpenQA.Selenium.By]::TagName("button"))
                    foreach ($btn in $buttons) {
                        $class = $btn.GetAttribute("class")
                        $text = $btn.Text
                        if (-not (($class -like "*cancel*") -or ($class -like "*close*") -or ($text -like "*Cancel*") -or ($text -like "*Close*"))) {
                            $saveButton = $btn
                            Write-Host "Found potential save button: Class='$class', Text='$text'" -ForegroundColor Green
                            break
                        }
                    }
                }
            }
        }
        
        if (-not $saveButton) {
            throw "Save button not found"
        }
        
        Write-Host "Clicking save button..." -ForegroundColor Cyan
        try {
        $saveButton.Click()
        } catch {
            Write-Host "Regular click failed, trying JavaScript click..." -ForegroundColor Yellow
            $driver.ExecuteScript("arguments[0].click();", $saveButton)
        }

        # Wait for success message or confirmation dialog
        Write-Host "Waiting for save confirmation..." -ForegroundColor Cyan
        Start-Sleep -Seconds 5  # Increased wait time
        
        # Verify that the certificate was saved successfully
        $successIndicator = $null
        try {
            # Look for success toast notification
            $successIndicator = $driver.FindElement([OpenQA.Selenium.By]::XPath("//*[contains(@class, 'toast-success')]"))
            if ($successIndicator) {
                Write-Host "Found success notification: $($successIndicator.Text)" -ForegroundColor Green
            }
        } catch {
            Write-Host "No success notification found, but this doesn't necessarily mean it failed." -ForegroundColor Yellow
        }

        # Check if any modal/popup is showing
        try {
            $modalButtons = $driver.FindElements([OpenQA.Selenium.By]::XPath("//div[contains(@class, 'modal')]//button"))
            if ($modalButtons.Count -gt 0) {
                Write-Host "Found modal with buttons, attempting to close it..." -ForegroundColor Yellow
                foreach ($button in $modalButtons) {
                    if ($button.Text -eq "Cancel" -or $button.Text -eq "Close" -or $button.Text -eq "No") {
                        Write-Host "Clicking button: $($button.Text)" -ForegroundColor Yellow
                        $button.Click()
                        Start-Sleep -Seconds 2
                        break
                    }
                }
            }
        } catch {
            Write-Host "Error checking for modal: $_" -ForegroundColor Red
        }
        
        # Refresh the page to ensure we see the updated certificate list
        Write-Host "Refreshing page to get updated certificate list..." -ForegroundColor Cyan
        $driver.Navigate().Refresh()
        Start-Sleep -Seconds 3  # Wait for page to reload
        
        # Get new certificate details
        Write-Host "Getting updated certificate details..." -ForegroundColor Cyan
        $newDetails = Get-CertificateDetails -Driver $driver
        Write-Host "BEFORE: Found $($existingDetails.Count) certificates with IDs: $($existingDetails.Ids -join ', ')" -ForegroundColor Cyan
        Write-Host "AFTER: Found $($newDetails.Count) certificates with IDs: $($newDetails.Ids -join ', ')" -ForegroundColor Cyan
        
        # Calculate new certificates
        $addedCount = $newDetails.Count - $existingDetails.Count
        
        # Find new IDs that weren't in the original list
        $newIds = @()
        foreach ($id in $newDetails.Ids) {
            if ($existingDetails.Ids -notcontains $id) {
                $newIds += $id
            }
        }
        
        if ($newIds.Count -gt 0) {
            Write-Host "Found $($newIds.Count) new certificate IDs: $($newIds -join ', ')" -ForegroundColor Green
            $certificateId = $newIds[0]  # Use the first new ID if multiple were added
            Write-Host "Using new certificate ID: $certificateId" -ForegroundColor Green
        } elseif ($addedCount -gt 0) {
            Write-Host "New certificates were added but couldn't find their IDs - using count as estimate" -ForegroundColor Yellow
            $certificateId = $newDetails.Count  # Assume the ID is the count (last certificate added)
            Write-Host "Using certificate count as estimated ID: $certificateId" -ForegroundColor Yellow
        } else {
            Write-Host "No new certificates found. This might mean the certificate wasn't successfully added." -ForegroundColor Yellow
            
            # Fallback 1: Try to find a certificate with matching name
            $certificateName = "All-In-One Telehealth Platform - $Environment"
            Write-Host "Looking for certificate with name: '$certificateName'" -ForegroundColor Yellow
            
            $rows = $driver.FindElements([OpenQA.Selenium.By]::XPath("//table//tr"))
            $matchingRows = @()
            
            for ($i = 0; $i -lt $rows.Count; $i++) {
                try {
                    $rowText = $rows[$i].Text
                    if ($rowText -like "*$certificateName*") {
                        Write-Host "Found row $($i+1) containing our certificate name: $rowText" -ForegroundColor Green
                        $matchingRows += @{Index = $i; Text = $rowText; Row = $rows[$i]}
                    }
                } catch {
                    Write-Host "Error reading row $($i+1): $_" -ForegroundColor Red
                }
            }
            
            if ($matchingRows.Count -gt 0) {
                # Found matching rows, use the first one
                $matchingRow = $matchingRows[0]
                Write-Host "Using matching row: $($matchingRow.Text)" -ForegroundColor Green
                
                # Look for links in this row with certificate IDs
                $links = $matchingRow.Row.FindElements([OpenQA.Selenium.By]::TagName("a"))
                $foundId = $false
                
                if ($links.Count -gt 0) {
                    foreach ($link in $links) {
                        try {
                            $href = $link.GetAttribute("href")
                            
                            if ($href -match "/nginx/certificates/(\d+)") {
                                $idFromUrl = $matches[1]
                                Write-Host "Found Certificate ID in URL: $idFromUrl" -ForegroundColor Green
                                $certificateId = $idFromUrl
                                $foundId = $true
                                break
                            }
                        } catch {
                            Write-Host "Error getting link href: $_" -ForegroundColor Red
                        }
                    }
                }
                
                if (-not $foundId) {
                    # Fallback 2: Check for buttons with data-id
                    $buttons = $matchingRow.Row.FindElements([OpenQA.Selenium.By]::TagName("button"))
                    if ($buttons.Count -gt 0) {
                        foreach ($button in $buttons) {
                            try {
                                $dataId = $button.GetAttribute("data-id")
                                if ($dataId -and $dataId -ne "") {
                                    Write-Host "Found Certificate ID in button data-id: $dataId" -ForegroundColor Green
                                    $certificateId = $dataId
                                    $foundId = $true
                                    break
                                }
                            } catch {
                                Write-Host "Error getting button data-id: $_" -ForegroundColor Red
                            }
                        }
                    }
                }
                
                if (-not $foundId) {
                    # Fallback 3: Just use the row number + 1 (often a reasonable guess)
                    $certificateId = $matchingRow.Index + 1
                    Write-Host "Using row number as certificate ID fallback: $certificateId" -ForegroundColor Yellow
                }
            } else {
                Write-Host "Could not find any row containing our certificate name" -ForegroundColor Yellow
                $certificateId = $null
            }
        }
        
        # Report the certificate ID if found
        if ($certificateId -and $certificateId -ne 0) {
            Write-Host "Successfully identified certificate with ID: $certificateId" -ForegroundColor Green
        } else {
            Write-Host "Could not determine the certificate ID" -ForegroundColor Yellow
        }
        
        # Wait for everything to settle
        Start-Sleep -Seconds 5
        
        Write-Host "SSL certificates configured successfully" -ForegroundColor Green
        return $certificateId
    }
    catch {
        Write-Host "Failed to configure SSL certificates: $_" -ForegroundColor Red
        return $null
    }
}

# First, ensure ChromeDriver is up-to-date
Write-Host "Checking ChromeDriver version and updating if necessary..." -ForegroundColor Cyan
$updateChromeDriverScript = Join-Path $PSScriptRoot "update-chromedriver.ps1"
if (Test-Path $updateChromeDriverScript) {
    Write-Host "Running ChromeDriver update script: $updateChromeDriverScript" -ForegroundColor Cyan
    & $updateChromeDriverScript -DownloadDirectory $seleniumPath -Force:$ForceReinstall
} else {
    Write-Host "ChromeDriver update script not found at: $updateChromeDriverScript" -ForegroundColor Yellow
    Write-Host "Continuing with existing ChromeDriver (if available)" -ForegroundColor Yellow
}

# Main script execution
try {
    # Check for ChromeDriver
    if (-not (Test-FileExists $chromeDriverPath)) {
        throw "ChromeDriver not found at: $chromeDriverPath"
    }

    # Load Selenium assemblies
    if (-not (Load-SeleniumAssemblies)) {
        throw "Failed to load Selenium assemblies"
    }

    # Create Chrome options
    $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
    if ($Headless) {
        $chromeOptions.AddArgument('--headless')
    }
    $chromeOptions.AddArgument('--no-sandbox')
    $chromeOptions.AddArgument('--disable-dev-shm-usage')
    $chromeOptions.AddArgument('--start-maximized')
    
    # Create Chrome driver
    Write-Host "Initializing Chrome WebDriver..." -ForegroundColor Cyan
    $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($chromeDriverPath, $chromeOptions)

    try {
        # Navigate to NPM login page
        Write-Host "Navigating to NPM login page: $NpmUrl" -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($NpmUrl)

        # Login to NPM
        if (-not (Login-ToNPM -Driver $driver -Email $DefaultEmail -Password $DefaultPassword)) {
            # If login fails, wait for user input before closing
            Write-Host "Press Enter to close the browser..." -ForegroundColor Yellow
            Read-Host
            throw "Failed to login to NPM"
        }

        # Configure SSL certificates
        if ($driver) {
            $certificateId = Configure-SSLCertificates -driver $driver -envConfig $envConfig -Environment $Environment -DefaultEmail $DefaultEmail
            
            if ($certificateId) {
                Write-Host "SSL certificate configuration completed successfully with ID: $certificateId" -ForegroundColor Green
                # Create an output variable that can be used by other scripts
                Write-Output "CERTIFICATE_ID=$certificateId"
            } else {
            # If SSL configuration fails, wait for user input before closing
            Write-Host "Press Enter to close the browser..." -ForegroundColor Yellow
            Read-Host
            throw "Failed to configure SSL certificates"
        }
        } else {
            throw "WebDriver not initialized"
        }
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        # On any error, wait for user input before closing
        Write-Host "Press Enter to close the browser..." -ForegroundColor Yellow
        Read-Host
        throw
    }
    finally {
        # Cleanup
        if ($driver) {
            $driver.Quit()
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}
finally {
    # Ensure driver is closed
    if ($driver) {
        $driver.Quit()
    }
} 