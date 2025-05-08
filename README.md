# OpenEMR Deployment

This repository contains PowerShell scripts for deploying and configuring OpenEMR along with related services in a Docker environment.

## Overview

The deployment scripts support multiple environments (dev, staging, test, production) and handle the following components:

- OpenEMR (with telehealth integration)
- Telehealth module
- Jitsi (for video conferencing)
- Nginx Proxy Manager (for routing)

## Setup Instructions

### Prerequisites

- Windows with PowerShell 5.1 or higher
- Docker and Docker Compose
- Git

### Quick Start

1. Clone this repository:
   ```
   git clone https://github.com/jmdurant/openemr-deployment.git
   cd openemr-deployment
   ```

2. Run the setup script with development mode:
   ```
   .\setup.ps1 -Environment dev -Project jmdurant
   ```

3. For more options, use:
   ```
   .\backup-and-staging.ps1 -Environment dev -Project jmdurant -RunSetup
   ```

### Development Mode Features

In development mode, the scripts:

1. Mount source repositories as Docker volumes for live code editing
2. Apply necessary fixes for development environment
3. Configure database connections
4. Set up Nginx with proper rewrite rules
5. Create custom_modules directory for module development

## Fixes and Enhancements

### Module Installer Fix

The deployment includes an automatic fix for OpenEMR's Module Installer issues. This resolves the following errors:

- "Undefined constant 'dpath'" error
- "readdir(): Argument #1 must be of type resource, string given" error
- "closedir(): Argument #1 must be of type resource, string given" error

The fix is applied automatically in development mode after OpenEMR is deployed.

### Nginx Configuration

The scripts ensure proper Nginx configuration with rewrite rules for:
- Zend modules
- Patient portal
- REST API/FHIR
- OAuth2

## Configuration Files

Key configuration files:

- `setup.ps1`: Main setup script
- `backup-and-staging.ps1`: Environment creation and backup
- `update-source-repos.ps1`: Source repository management
- `environment-config.ps1`: Environment-specific configuration
- `network-setup.ps1`: Docker network configuration

## Troubleshooting

### Blank Screen After Login

If you encounter a blank screen after login, the script provides an option to fix OpenEMR encryption keys:
```
Would you like to fix OpenEMR encryption keys (needed if you see blank screen issues)? (y/n)
```

### Module Installer Issues

For module installer issues, the script includes an automatic fix that can be applied:
```
Would you like to fix OpenEMR module installer issues? (y/n)
```

## License

This project is licensed under the MIT License - see the LICENSE file for details. 