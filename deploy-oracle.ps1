param(
    [string]$DeploymentZip,  # Path to your previously created deployment zip
    [string]$TerraformDir = "$PSScriptRoot\infrastructure-oci"
)

function Ensure-Terraform {
    $terraformExe = "terraform.exe"
    $terraformExtractDir = Join-Path $PSScriptRoot "terraform-bin"
    $terraformPath = $null
    $found = $false
    $env:PATH.Split(';') | ForEach-Object {
        if (Test-Path (Join-Path $_ $terraformExe)) {
            $found = $true
            $terraformPath = Join-Path $_ $terraformExe
        }
    }
    if (-not $found) {
        Write-Host "Terraform not found in PATH. Downloading latest version..." -ForegroundColor Cyan
        $releasesUrl = "https://releases.hashicorp.com/terraform/"
        $html = Invoke-WebRequest -Uri $releasesUrl -UseBasicParsing
        $version = ($html.Links | Where-Object { $_.href -match "^/terraform/1\.[0-9]+\.[0-9]+/?$" } | ForEach-Object { $_.href -replace "/terraform/|/$", "" } | Sort-Object -Descending | Select-Object -First 1)
        if (-not $version) { $version = "1.7.5" }
        $terraformZipUrl = "https://releases.hashicorp.com/terraform/$version/terraform_${version}_windows_amd64.zip"
        $terraformZipPath = Join-Path $PSScriptRoot "terraform_${version}_windows_amd64.zip"
        Invoke-WebRequest -Uri $terraformZipUrl -OutFile $terraformZipPath
        if (-not (Test-Path $terraformExtractDir)) {
            New-Item -ItemType Directory -Path $terraformExtractDir | Out-Null
        }
        Expand-Archive -Path $terraformZipPath -DestinationPath $terraformExtractDir -Force
        Remove-Item $terraformZipPath -Force
        $terraformPath = Join-Path $terraformExtractDir $terraformExe
        $env:PATH = "$terraformExtractDir;$env:PATH"
        Write-Host "Terraform $version downloaded and available at $terraformPath" -ForegroundColor Green
    } else {
        Write-Host "Terraform found in PATH at $terraformPath" -ForegroundColor Green
    }
    return $terraformPath
}

# 1. Ensure Terraform is available
$TerraformExePath = Ensure-Terraform

# 2. Copy the deployment zip to the resources directory
if (-not $DeploymentZip -or -not (Test-Path $DeploymentZip)) {
    Write-Host "ERROR: Please specify a valid deployment zip file with -DeploymentZip" -ForegroundColor Red
    exit 1
}
$destZip = Join-Path $TerraformDir "resources\docker-wireguard-unbound.zip"
Copy-Item -Path $DeploymentZip -Destination $destZip -Force
Write-Host "Copied $DeploymentZip to $destZip" -ForegroundColor Green

# 3. Run Terraform commands
Push-Location $TerraformDir
try {
    Write-Host "Running: terraform init" -ForegroundColor Cyan
    & $TerraformExePath init
    Write-Host "Running: terraform plan" -ForegroundColor Cyan
    & $TerraformExePath plan
    Write-Host "Running: terraform apply" -ForegroundColor Cyan
    & $TerraformExePath apply
} catch {
    Write-Host "Error running Terraform: $_" -ForegroundColor Red
} finally {
    Pop-Location
} 