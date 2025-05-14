# Run this script as Administrator
param(
    [string]$Project = "official",
    [string]$Environment = "staging",
    [string]$DomainBase = "vr2fit.com"
)

$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$entries = @"

# $Project-$Environment environment entries
127.0.0.1 $Environment-$Project.$DomainBase
127.0.0.1 vc-$Environment-$Project.$DomainBase
127.0.0.1 vcbknd-$Environment-$Project.$DomainBase
"@

Add-Content -Path $hostsFile -Value $entries -Force
Write-Host "Hosts file updated successfully!" -ForegroundColor Green
