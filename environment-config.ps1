# Environment Configuration Script for AIO Telehealth Platform
# This script centralizes all environment-specific configuration settings

param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$SourceReposDir = "$PSScriptRoot\source-repos",
    [string]$Project = "aiotp",  # Default project is "aiotp", can be overridden with other projects like "jmdurant"
    [string]$DomainBase = "localhost"  # Default domain base is "localhost", can be overridden with custom domains
)

# Define port offset multipliers for different projects to avoid port conflicts
$projectOffsets = @{
    "aiotp" = 0       # Base project (no additional offset)
    "jmdurant" = 100  # jmdurant's fork gets +100 to all port offsets
    "official" = 200  # Official OpenEMR repo gets +200 to all port offsets
    # Add more projects as needed with their respective offsets
}

# Base configuration for production environment
$config = @{
    production = @{
        dirName = "$Project-production"
        projectName = "$Project-production"
        portOffset = 0 + ($projectOffsets[$Project] * 1)
        containerPorts = @{
            openemr = @{
                http = "30080"
                https = "30081"
                ws = "3001"
                mysql = "30006"
                telehealth_port = "443"
            }
            telehealth = @{
                app = "8000"
                web = "31080"
                https = "31443"
                db = "31006"
                db_port = "3306"
                api_token = ""  # Will be set during setup
            }
            jitsi = @{
                http = "32080"
                https = "32443"
                xmpp = "5222"
                jvb = "10000"
            }
        }
        npmPorts = @{
            http = "80"
            https = "443"
            admin = "81"
        }
        domains = @{
            openemr = "localhost"
            telehealth = "vc.localhost"
            jitsi = "vcbknd.localhost"
        }
    }
    staging = @{
        dirName = "$Project-staging"
        projectName = "$Project-staging"
        portOffset = 10 + ($projectOffsets[$Project] * 1)
        containerPorts = @{
            openemr = @{
                http = "30090"
                https = "30091"
                ws = "3011"
                mysql = "30016"
                telehealth_port = "443"
            }
            telehealth = @{
                app = "8010"
                web = "31090"
                https = "31453"
                db = "31016"
                db_port = "3316"
                api_token = ""  # Will be set during setup
            }
            jitsi = @{
                http = "32080"
                https = "32443"
                xmpp = "5222"
                jvb = "10000"
            }
        }
        npmPorts = @{
            http = "8081"
            https = "8443"
            admin = "91"
        }
        domains = @{
            openemr = "staging.localhost"
            telehealth = "vc-staging.localhost"
            jitsi = "vcbknd-staging.localhost"
        }
    }
    dev = @{
        dirName = "$Project-dev"
        projectName = "$Project-dev"
        portOffset = 20 + ($projectOffsets[$Project] * 1)
        containerPorts = @{
            openemr = @{
                http = "30100"
                https = "30101"
                ws = "3021"
                mysql = "30026"
                telehealth_port = "443"
            }
            telehealth = @{
                app = "8020"
                web = "31100"
                https = "31463"
                db = "31026"
                db_port = "3326"
                api_token = ""  # Will be set during setup
            }
            jitsi = @{
                http = "32080"
                https = "32443"
                xmpp = "5222"
                jvb = "10000"
            }
        }
        npmPorts = @{
            http = "8082"
            https = "8463"
            admin = "101"
        }
        domains = @{
            openemr = "dev.localhost"
            telehealth = "vc-dev.localhost"
            jitsi = "vcbknd-dev.localhost"
        }
    }
    test = @{
        dirName = "$Project-test"
        projectName = "$Project-test"
        portOffset = 30 + ($projectOffsets[$Project] * 1)
        containerPorts = @{
            openemr = @{
                http = "30110"
                https = "30111"
                ws = "3031"
                mysql = "30036"
                telehealth_port = "443"
            }
            telehealth = @{
                app = "8030"
                web = "31110"
                https = "31473"
                db = "31036"
                db_port = "3336"
                api_token = ""  # Will be set during setup
            }
            jitsi = @{
                http = "32080"
                https = "32443"
                xmpp = "5222"
                jvb = "10000"
            }
        }
        npmPorts = @{
            http = "8083"
            https = "8473"
            admin = "111"
        }
        domains = @{
            openemr = "test.localhost"
            telehealth = "vc-test.localhost"
            jitsi = "vcbknd-test.localhost"
        }
    }
}

# Adjust specific port values based on project offsets
# This ensures all ports are unique across projects
if ($Project -ne "aiotp") {
    # Calculate offsets for non-default projects
    $offset = $projectOffsets[$Project]
    
    # Adjust NPM ports
    $config[$Environment].npmPorts.admin = [int]$config[$Environment].npmPorts.admin + $offset
    
    if ($Environment -ne "production") {
        # For non-production environments, also adjust http and https ports
        $config[$Environment].npmPorts.http = [int]$config[$Environment].npmPorts.http + $offset
        $config[$Environment].npmPorts.https = [int]$config[$Environment].npmPorts.https + $offset
    }
    
    # Adjust container ports
    $config[$Environment].containerPorts.openemr.http = [int]$config[$Environment].containerPorts.openemr.http + $offset
    $config[$Environment].containerPorts.openemr.https = [int]$config[$Environment].containerPorts.openemr.https + $offset
    $config[$Environment].containerPorts.openemr.mysql = [int]$config[$Environment].containerPorts.openemr.mysql + $offset
    $config[$Environment].containerPorts.telehealth.web = [int]$config[$Environment].containerPorts.telehealth.web + $offset
    $config[$Environment].containerPorts.telehealth.db = [int]$config[$Environment].containerPorts.telehealth.db + $offset
}

# Always modify domain names based on DomainBase parameter, regardless of project
# This ensures custom domains work for all projects
if ($Environment -eq "production") {
    $config[$Environment].domains.openemr = "$Project.$DomainBase"
    $config[$Environment].domains.telehealth = "vc-$Project.$DomainBase"
    $config[$Environment].domains.jitsi = "vcbknd-$Project.$DomainBase"
} else {
    $prefix = $Environment.ToLower()
    $config[$Environment].domains.openemr = "$prefix-$Project.$DomainBase"
    $config[$Environment].domains.telehealth = "vc-$prefix-$Project.$DomainBase"
    $config[$Environment].domains.jitsi = "vcbknd-$prefix-$Project.$DomainBase"
}

# Folder names for components (consistent across all environments)
$folderNames = @{
    openemr = "openemr"
    telehealth = "telehealth"
    jitsi = "jitsi-docker"
    proxy = "proxy"
}

# Network names based on environment and project
$networks = @{
    frontend = "frontend-$Project-$Environment"
    proxy = "proxy-$Project-$Environment"
}

# Define repository sources
$repositorySources = @{
    "aiotp" = @{
        openemr = "https://github.com/ciips-code/openemr-telesalud.git"
        telehealth = "https://github.com/ciips-code/telesalud-webapp.git"
        jitsi = "https://github.com/jitsi/docker-jitsi-meet.git"
    }
    "jmdurant" = @{
        openemr = "https://github.com/jmdurant/openemr-aio.git"
        telehealth = "https://github.com/ciips-code/telesalud-webapp.git"  # Using original telehealth repo
        jitsi = "https://github.com/jitsi/docker-jitsi-meet.git"  # Using original jitsi repo
    }
    "official" = @{
        openemr = "https://github.com/openemr/openemr.git"
        telehealth = "https://github.com/ciips-code/telesalud-webapp.git"  # Using original telehealth repo
        jitsi = "https://github.com/jitsi/docker-jitsi-meet.git"  # Using original jitsi repo
    }
    # Add more project-specific repository sources as needed
}

# Return the configuration
@{
    # Basic environment info
    Environment = $Environment
    Project = $Project
    ProjectName = $config[$Environment].projectName
    DirectoryName = $config[$Environment].dirName
    
    # Network configurations
    Networks = $networks
    FrontendNetwork = $networks.frontend
    ProxyNetwork = $networks.proxy
    
    # Port configurations
    PortOffset = $config[$Environment].portOffset
    ProjectOffset = $projectOffsets[$Project]
    ContainerPorts = $config[$Environment].containerPorts
    NpmPorts = $config[$Environment].npmPorts
    
    # Domain and folder configurations
    Domains = $config[$Environment].domains
    FolderNames = $folderNames
    
    # Repository configurations
    RepositorySources = $repositorySources[$Project]
    
    # Full environment config for reference
    Config = $config[$Environment]
}
