# Script to update container hosts files with domain mappings
# This allows containers to communicate using domain names instead of container names
#
# Usage:
#   .\update-container-hosts.ps1                                      # Default: official-staging
#   .\update-container-hosts.ps1 -Project "myproject" -Environment "prod" # Custom project/environment
#
# Parameters:
#   -Project      : Project name for container naming (default: "official")
#   -Environment  : Environment name for container naming (default: "staging")
#
# Container Pattern: {Project}-{Environment}-{service}-1
# Domain Pattern: {Environment}-notes.localhost, vc-{Environment}.localhost
#   Examples:
#     Containers: official-staging-openemr-1, official-staging-telehealth-web-1
#     Domains: staging-notes.localhost, vc-staging.localhost

param(
    [string]$Project = "official",
    [string]$Environment = "staging"
)

# Define container names using parameters
$openemrContainer = "$Project-$Environment-openemr-1"
$telehealthContainer = "$Project-$Environment-telehealth-web-1"
$networkName = "$Project-$Environment-network"

# Jitsi container (standalone, not parameterized)
$jitsiContainer = "jitsi-docker-web-1"

# Define domain names using environment parameter
$openemrDomain = "$Environment-notes.localhost"
$telehealthDomain = "vc-$Environment.localhost"
$jitsiDomain = "vcbknd-$Environment.localhost"

Write-Host "Container Communication Setup:" -ForegroundColor Cyan
Write-Host "  Project: $Project" -ForegroundColor Gray
Write-Host "  Environment: $Environment" -ForegroundColor Gray
Write-Host "  Network: $networkName" -ForegroundColor Gray
Write-Host "  OpenEMR Container: $openemrContainer" -ForegroundColor Gray
Write-Host "  Telehealth Container: $telehealthContainer" -ForegroundColor Gray
Write-Host ""

Write-Host "Discovering container IPs..."

# Get OpenEMR container IP from the project-environment network
$openemrIp = (docker inspect -f "{{range `$key, `$value := .NetworkSettings.Networks}}{{if eq `$key `"$networkName`"}}{{`$value.IPAddress}}{{end}}{{end}}" $openemrContainer).Trim()

# If not found in project-environment network, try any network
if (-not $openemrIp) {
    $openemrIp = (docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$value.IPAddress}}{{break}}{{end}}' $openemrContainer).Trim()
}

# Get Telehealth container IP from the project-environment network
$telehealthIp = (docker inspect -f "{{range `$key, `$value := .NetworkSettings.Networks}}{{if eq `$key `"$networkName`"}}{{`$value.IPAddress}}{{end}}{{end}}" $telehealthContainer).Trim()

# If not found in project-environment network, try any network
if (-not $telehealthIp) {
    $telehealthIp = (docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$value.IPAddress}}{{break}}{{end}}' $telehealthContainer).Trim()
}

# Get Jitsi container IP - try meet.jitsi network first, then any network
$jitsiIp = (docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{if eq $key "meet.jitsi"}}{{$value.IPAddress}}{{end}}{{end}}' $jitsiContainer 2>$null).Trim()

# If not found in meet.jitsi network, try any network
if (-not $jitsiIp) {
    $jitsiIp = (docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$value.IPAddress}}{{break}}{{end}}' $jitsiContainer 2>$null).Trim()
}

# Check if IPs were found
if (-not $openemrIp) {
    Write-Host "Error: Could not determine IP address for $openemrContainer" -ForegroundColor Red
    exit 1
}

if (-not $telehealthIp) {
    Write-Host "Error: Could not determine IP address for $telehealthContainer" -ForegroundColor Red
    exit 1
}

# Jitsi container is optional, so just warn if not found
$jitsiFound = $false
if (-not $jitsiIp) {
    Write-Host "Warning: Could not determine IP address for $jitsiContainer - skipping Jitsi host entries" -ForegroundColor Yellow
} else {
    $jitsiFound = $true
}

Write-Host "Found container IPs:" -ForegroundColor Green
Write-Host "  $openemrContainer -> $openemrIp"
Write-Host "  $telehealthContainer -> $telehealthIp"
if ($jitsiFound) {
    Write-Host "  $jitsiContainer -> $jitsiIp"
}

# Update hosts file in OpenEMR container
Write-Host "Updating hosts file in $openemrContainer..."
$hostEntry = "$telehealthIp $telehealthDomain"
$command = "grep -q '$telehealthDomain' /etc/hosts || echo '$hostEntry' >> /etc/hosts"
docker exec $openemrContainer sh -c "$command"
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Added $hostEntry to $openemrContainer hosts file" -ForegroundColor Green
} else {
    Write-Host "  Failed to update hosts file in $openemrContainer" -ForegroundColor Red
}

# Update hosts file in Telehealth container
Write-Host "Updating hosts file in $telehealthContainer..."
$hostEntry = "$openemrIp $openemrDomain"
$command = "grep -q '$openemrDomain' /etc/hosts || echo '$hostEntry' >> /etc/hosts"
docker exec $telehealthContainer sh -c "$command"
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Added $hostEntry to $telehealthContainer hosts file" -ForegroundColor Green
} else {
    Write-Host "  Failed to update hosts file in $telehealthContainer" -ForegroundColor Red
}

# Update hosts files with Jitsi entries if Jitsi was found
if ($jitsiFound) {
    # Add Jitsi entry to OpenEMR container
    Write-Host "Updating hosts file in $openemrContainer with Jitsi entry..."
    $hostEntry = "$jitsiIp $jitsiDomain"
    $command = "grep -q '$jitsiDomain' /etc/hosts || echo '$hostEntry' >> /etc/hosts"
    docker exec $openemrContainer sh -c "$command"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Added $hostEntry to $openemrContainer hosts file" -ForegroundColor Green
    } else {
        Write-Host "  Failed to update hosts file in $openemrContainer with Jitsi entry" -ForegroundColor Red
    }
    
    # Add Jitsi entry to Telehealth container
    Write-Host "Updating hosts file in $telehealthContainer with Jitsi entry..."
    $command = "grep -q '$jitsiDomain' /etc/hosts || echo '$hostEntry' >> /etc/hosts"
    docker exec $telehealthContainer sh -c "$command"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Added $hostEntry to $telehealthContainer hosts file" -ForegroundColor Green
    } else {
        Write-Host "  Failed to update hosts file in $telehealthContainer with Jitsi entry" -ForegroundColor Red
    }
}

Write-Host "Done! Containers can now communicate using domain names:" -ForegroundColor Green
Write-Host "  From $openemrContainer -> $telehealthDomain"
Write-Host "  From $telehealthContainer -> $openemrDomain"
if ($jitsiFound) {
    Write-Host "  From both containers -> $jitsiDomain"
}
