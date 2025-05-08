# Check for environment parameters and force parameter
param(
    [Parameter(Mandatory=$true)]
    [string]$Environment = "production",
    [switch]$StagingEnvironment = $false,  # Keep for backward compatibility
    [switch]$Force = $false,
    [int]$ValidityDays = 3650,  # Default to 10 years
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",  # Path to source repositories
    [string]$Project = "aiotp"  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
)

# Handle backward compatibility with -StagingEnvironment switch
if ($StagingEnvironment -and -not $Environment) {
    $Environment = "staging"
}

# Load environment configuration
$envConfig = & "$PSScriptRoot\environment-config.ps1" -Environment $Environment -Project $Project
if (-not $envConfig) {
    Write-Error "Failed to load environment configuration"
    exit 1
}

Write-Host "Loaded configuration for project: $Project, environment: $Environment" -ForegroundColor Green

# Get domains from environment config
$domains = @{
    "openemr" = $envConfig.Domains.openemr
    "telehealth" = $envConfig.Domains.telehealth
    "jitsi" = $envConfig.Domains.jitsi
}

# Set certificate details
$certDetails = @{
    "C" = "US"                                # Country
    "ST" = "California"                       # State
    "L" = "San Francisco"                     # Locality
    "O" = "All-In-One Telehealth Platform"    # Organization
    "OU" = "IT Department"                    # Organizational Unit
    "CN" = $domains.openemr                   # Common Name (use openemr domain)
    "emailAddress" = "admin@example.com"      # Email Address
}

# Create certificates directory if it doesn't exist
$sslDir = Join-Path -Path $PSScriptRoot -ChildPath "ssl"
$projectSslDir = Join-Path -Path $sslDir -ChildPath $Project
$envSslDir = Join-Path -Path $projectSslDir -ChildPath $Environment

if (-not (Test-Path -Path $projectSslDir)) {
    New-Item -Path $projectSslDir -ItemType Directory -Force | Out-Null
    Write-Host "Created SSL directory for project: $projectSslDir" -ForegroundColor Green
}

if (-not (Test-Path -Path $envSslDir)) {
    New-Item -Path $envSslDir -ItemType Directory -Force | Out-Null
    Write-Host "Created SSL directory for environment: $envSslDir" -ForegroundColor Green
}

# Set file paths using standard names
$privateKeyPath = Join-Path -Path $envSslDir -ChildPath "cert.key"
$certificatePath = Join-Path -Path $envSslDir -ChildPath "cert.crt"
$csrPath = Join-Path -Path $envSslDir -ChildPath "request.csr"
$opensslConfigPath = Join-Path -Path $envSslDir -ChildPath "openssl.cnf"
$pemCertPath = Join-Path -Path $envSslDir -ChildPath "fullchain.pem"
$pemKeyPath = Join-Path -Path $envSslDir -ChildPath "privkey.pem"

# Create OpenSSL configuration file
$opensslConfig = @"
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = $($certDetails.C)
ST = $($certDetails.ST)
L = $($certDetails.L)
O = $($certDetails.O)
OU = $($certDetails.OU)
CN = $($certDetails.CN)
emailAddress = $($certDetails.emailAddress)

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $($domains.openemr)
DNS.2 = $($domains.telehealth)
DNS.3 = $($domains.jitsi)
"@

Set-Content -Path $opensslConfigPath -Value $opensslConfig
Write-Host "Created OpenSSL configuration file: $opensslConfigPath" -ForegroundColor Green

# Function to check if a certificate is valid and not expired
function Test-CertificateValidity {
    param (
        [string]$CertPath,
        [int]$WarningDays = 30
    )
    
    try {
        if (-not (Test-Path -Path $CertPath)) {
            return $false
        }
        
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath
        $expirationDate = $cert.NotAfter
        $daysUntilExpiration = ($expirationDate - (Get-Date)).Days
        
        Write-Host "Certificate at $CertPath expires on $expirationDate ($daysUntilExpiration days remaining)" -ForegroundColor Yellow
        
        if ($daysUntilExpiration -lt $WarningDays) {
            Write-Host "WARNING: Certificate will expire in less than $WarningDays days!" -ForegroundColor Red
            return $false
        }
        
        return $true
    } catch {
        Write-Host "Error checking certificate validity: $_" -ForegroundColor Red
        return $false
    }
}

# Check if OpenSSL is installed
$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $openssl) {
    Write-Host "OpenSSL is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Please install OpenSSL and make sure it's in your PATH." -ForegroundColor Yellow
    Write-Host "You can download it from https://slproweb.com/products/Win32OpenSSL.html" -ForegroundColor Yellow
    exit 1
}

# Check if certificates already exist and are valid
$certificateExists = (Test-Path -Path $certificatePath) -and (Test-Path -Path $privateKeyPath)
$certificateValid = $false

if ($certificateExists) {
    $certificateValid = (Test-CertificateValidity -CertPath $certificatePath)
}

if ($certificateExists -and $certificateValid -and -not $Force) {
    Write-Host "SSL certificates already exist and are valid:" -ForegroundColor Green
    Write-Host "  Certificate: $certificatePath" -ForegroundColor Green
    Write-Host "  Private Key: $privateKeyPath" -ForegroundColor Green
    Write-Host "Use -Force to regenerate certificates." -ForegroundColor Yellow
    exit 0
}

# Generate private key
Write-Host "Generating private key: $privateKeyPath" -ForegroundColor Yellow
openssl genrsa -out $privateKeyPath 2048
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to generate private key." -ForegroundColor Red
    exit 1
}
Write-Host "Private key generated successfully." -ForegroundColor Green

# Generate certificate signing request
Write-Host "Generating certificate signing request: $csrPath" -ForegroundColor Yellow
openssl req -new -key $privateKeyPath -out $csrPath -config $opensslConfigPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to generate certificate signing request." -ForegroundColor Red
    exit 1
}
Write-Host "Certificate signing request generated successfully." -ForegroundColor Green

# Generate self-signed certificate
Write-Host "Generating self-signed certificate: $certificatePath" -ForegroundColor Yellow
openssl x509 -req -days $ValidityDays -in $csrPath -signkey $privateKeyPath -out $certificatePath -extensions req_ext -extfile $opensslConfigPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to generate self-signed certificate." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Self-signed certificate generated successfully." -ForegroundColor Green
}

# Create .pem files in the same directory
Write-Host "Creating .pem files..." -ForegroundColor Yellow
Copy-Item -Path $certificatePath -Destination $pemCertPath -Force
Copy-Item -Path $privateKeyPath -Destination $pemKeyPath -Force
Write-Host "Created .pem files:" -ForegroundColor Green
Write-Host "  Certificate: $pemCertPath" -ForegroundColor Green
Write-Host "  Private Key: $pemKeyPath" -ForegroundColor Green

# Clean up temporary files
Remove-Item -Path $csrPath -Force
Remove-Item -Path $opensslConfigPath -Force

# Verify certificate
Write-Host "Verifying certificate..." -ForegroundColor Yellow
openssl x509 -in $certificatePath -text -noout | Select-String -Pattern "Subject:|Issuer:|Not Before:|Not After :|DNS:"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to verify certificate." -ForegroundColor Red
    exit 1
}

# Create backward compatibility links in the environment-specific location
$envDir = Join-Path -Path $PSScriptRoot -ChildPath "$Project-$Environment"
$oldSslDir = Join-Path -Path $envDir -ChildPath "ssl"

# Create the environment ssl directory if it doesn't exist
if (-not (Test-Path -Path $oldSslDir)) {
    New-Item -Path $oldSslDir -ItemType Directory -Force | Out-Null
    Write-Host "Created backward compatibility SSL directory: $oldSslDir" -ForegroundColor Green
}

# Create copies for backward compatibility
Write-Host "Creating backward compatibility copies..." -ForegroundColor Yellow
if (Test-Path -Path $privateKeyPath) {
    Copy-Item -Path $privateKeyPath -Destination "$oldSslDir\private.key" -Force
    Write-Host "Created copy of private key" -ForegroundColor Green
}
if (Test-Path -Path $certificatePath) {
    Copy-Item -Path $certificatePath -Destination "$oldSslDir\certificate.crt" -Force
    Write-Host "Created copy of certificate" -ForegroundColor Green
}

# Copy certificates to Telehealth docker-config directory
$telehealthDir = Join-Path -Path $envDir -ChildPath "telehealth"
$dockerConfigDir = Join-Path -Path $telehealthDir -ChildPath "docker-config"

# Create docker-config directory if it doesn't exist
if (-not (Test-Path -Path $dockerConfigDir)) {
    New-Item -Path $dockerConfigDir -ItemType Directory -Force | Out-Null
    Write-Host "Created Telehealth docker-config directory: $dockerConfigDir" -ForegroundColor Green
}

# Copy certificates to docker-config directory
Copy-Item -Path $certificatePath -Destination (Join-Path -Path $dockerConfigDir -ChildPath "cert.crt") -Force
Copy-Item -Path $privateKeyPath -Destination (Join-Path -Path $dockerConfigDir -ChildPath "cert.key") -Force

Write-Host "Copied certificates to Telehealth docker-config directory:" -ForegroundColor Green
Write-Host "  $certificatePath -> $dockerConfigDir\cert.crt" -ForegroundColor Green
Write-Host "  $privateKeyPath -> $dockerConfigDir\cert.key" -ForegroundColor Green

# Copy certificates to NPM container if it's running
$npmContainer = docker ps --format "{{.Names}}" | Where-Object { $_ -match "nginx-proxy-manager" } | Select-Object -First 1
if ($npmContainer) {
    Write-Host "Found NPM container: $npmContainer" -ForegroundColor Green
    
    # Create certificate directory in container
    $containerCertDir = "/etc/letsencrypt/live/npm-$($domains.telehealth)"
    docker exec $npmContainer sh -c "mkdir -p $containerCertDir"
    
    # Copy certificate and key to container
    Get-Content $certificatePath | docker exec -i $npmContainer sh -c "cat > $containerCertDir\fullchain.pem"
    Get-Content $privateKeyPath | docker exec -i $npmContainer sh -c "cat > $containerCertDir\privkey.pem"
    
    # Set proper permissions
    docker exec $npmContainer sh -c "chmod 600 $containerCertDir\privkey.pem"
    
    Write-Host "Copied certificates to NPM container:" -ForegroundColor Green
    Write-Host "  $certificatePath -> $containerCertDi\fullchain.pem" -ForegroundColor Green
    Write-Host "  $privateKeyPath -> $containerCertDir\privkey.pem" -ForegroundColor Green
}

Write-Host "SSL certificate generation completed successfully!" -ForegroundColor Green
Write-Host "Certificates are located in: $envSslDir" -ForegroundColor Green
Write-Host "Backward compatibility links are in: $oldSslDir" -ForegroundColor Green
