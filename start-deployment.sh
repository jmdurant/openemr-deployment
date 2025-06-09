#!/bin/bash
# Deployment Startup Script for All-In-One Telehealth Platform
# This script starts all components and ensures proper network connections

# Function to reset deployment (stop containers, remove volumes and networks)
reset_deployment() {
    local project_name=$1
    local environment=$2
    
    echo "===================================================="
    echo "RESETTING DEPLOYMENT"
    echo "Project: $project_name"
    echo "Environment: $environment"
    echo "===================================================="
    
    # First, explicitly handle Jitsi Docker components
    echo "Stopping and removing Jitsi Docker components..."
    if [ -d "jitsi-docker" ]; then
        echo "Found jitsi-docker directory, stopping containers..."
        cd jitsi-docker
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            if command -v docker-compose &> /dev/null; then
                docker-compose down -v
            else
                docker compose down -v
            fi
        fi
        cd ..
    fi
    
    # Explicitly stop containers with specific patterns known to cause issues
    echo "Explicitly stopping problematic containers..."
    docker ps -a --filter "name=jitsi" -q | xargs -r docker stop
    docker ps -a --filter "name=jicofo" -q | xargs -r docker stop
    docker ps -a --filter "name=prosody" -q | xargs -r docker stop
    docker ps -a --filter "name=jvb" -q | xargs -r docker stop
    
    # Stop all containers related to the project (using more inclusive patterns)
    echo "Stopping all containers related to the project..."
    docker ps -a --filter "name=$project_name" -q | xargs -r docker stop
    # Also stop containers that might only have the environment in their name
    docker ps -a --filter "name=$environment" -q | xargs -r docker stop
    
    # Remove all containers related to the project (using more inclusive patterns)
    echo "Removing all containers related to the project..."
    # Explicitly remove containers with specific patterns known to cause issues
    docker ps -a --filter "name=jitsi" -q | xargs -r docker rm -f
    docker ps -a --filter "name=jicofo" -q | xargs -r docker rm -f
    docker ps -a --filter "name=prosody" -q | xargs -r docker rm -f
    docker ps -a --filter "name=jvb" -q | xargs -r docker rm -f
    # Remove containers by project and environment
    docker ps -a --filter "name=$project_name" -q | xargs -r docker rm -f
    docker ps -a --filter "name=$environment" -q | xargs -r docker rm -f
    
    # Wait a moment to ensure containers are fully removed
    echo "Waiting for containers to be fully removed..."
    sleep 5
    
    # Remove all volumes related to the project (using more inclusive patterns)
    echo "Removing all volumes related to the project..."
    docker volume ls --filter "name=jitsi" -q | xargs -r docker volume rm
    docker volume ls --filter "name=$project_name" -q | xargs -r docker volume rm
    docker volume ls --filter "name=$environment" -q | xargs -r docker volume rm
    
    # Remove all networks related to the project (using more inclusive patterns)
    echo "Removing all networks related to the project..."
    # Create a comprehensive list of network patterns to match all possible networks
    network_patterns=(
        "$project_name"
        "proxy-$project_name"
        "frontend-$project_name"
        "proxy-$project_name-$environment"
        "frontend-$project_name-$environment"
        "${project_name}-shared-network"
        "${project_name}-proxy_default"
        "${project_name}_default"
        "jitsi"
    )
    
    # Loop through each pattern and remove matching networks
    for pattern in "${network_patterns[@]}"; do
        echo "Removing networks matching pattern: $pattern"
        docker network ls --filter "name=$pattern" -q | xargs -r docker network rm || echo "Some networks could not be removed (they may be in use)"
    done
    
    # Try to remove any remaining networks that might have been created by docker-compose
    echo "Checking for any remaining networks related to the project..."
    docker network ls | grep -E "$project_name|$environment|jitsi" | awk '{print $1}' | xargs -r docker network rm || echo "Some networks could not be removed (they may be in use)"
    
    # Final check for any remaining containers
    remaining_containers=$(docker ps -a --filter "name=$project_name" -q)
    if [ ! -z "$remaining_containers" ]; then
        echo "WARNING: Some containers still remain. Attempting forced removal..."
        docker ps -a --filter "name=$project_name" -q | xargs -r docker rm -f
    fi
    
    echo "Reset complete. You can now start a fresh deployment."
    exit 0
}

# Parse command line arguments
RESET_MODE=false
SHARED_DB_MODE=false
RESTART_NPM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain=*)
      OVERRIDE_DOMAIN_BASE="${1#*=}"
      shift
      ;;
    --reset)
      RESET_MODE=true
      shift
      ;;
    --restart-npm)
      RESTART_NPM=true
      shift
      ;;
    --shared-db)
      SHARED_DB_MODE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [--domain=yourdomain.com] [--reset] [--shared-db]"
      echo "Options:"
      echo "  --domain=DOMAIN   Override the domain base with DOMAIN"
      echo "  --reset          Stop all containers, remove volumes and networks"
      echo "  --shared-db      Use a single shared database container for all services (saves memory)"
      echo "  --help           Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Check which docker compose command is available
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
    echo "Using legacy docker-compose command"
else
    DOCKER_COMPOSE="docker compose"
    echo "Using modern docker compose command"
fi

# Environment-specific variables (will be replaced during deployment)
DEFAULT_DOMAIN_BASE="localhost"
PROJECT_NAME="official"
ENVIRONMENT="production"
NPM_ADMIN_PORT="281"
NPM_HTTP_PORT="80"
NPM_HTTPS_PORT="443"

# Define display name mapping (similar to environment-config.ps1)
# This ensures we use 'notes' instead of 'official' in URLs
if [ "$PROJECT_NAME" = "official" ] || [[ "$PROJECT_NAME" == *"official"* ]]; then
    DISPLAY_NAME="notes"
else
    DISPLAY_NAME="$PROJECT_NAME"
fi

echo "Using display name '$DISPLAY_NAME' for project '$PROJECT_NAME'"

# If reset mode is enabled, call reset_deployment and exit
if [ "$RESET_MODE" = true ]; then
    reset_deployment "$PROJECT_NAME" "$ENVIRONMENT"
    # The script will exit after reset_deployment is called
fi

# Setup shared database if requested
if [ "$SHARED_DB_MODE" = true ]; then
    echo "===================================================="
    echo "SETTING UP SHARED DATABASE"
    echo "This will configure all services to use a single MariaDB container"
    echo "===================================================="
    
    # Create shared database docker-compose file if it doesn't exist
    if [ ! -d "shared-db" ]; then
        mkdir -p shared-db
    fi
    
    # Create shared-db docker-compose.yml
    cat > shared-db/docker-compose.yml << EOL
services:
  shared-db:
    image: mariadb:latest
    container_name: ${PROJECT_NAME}-${ENVIRONMENT}-shared-db
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: root
      # These databases will be created if they don't exist
      MARIADB_DATABASE: shared
    volumes:
      - shared_db_data:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - default
      - ${PROJECT_NAME}-shared-network

volumes:
  shared_db_data:

networks:
  default:
  ${PROJECT_NAME}-shared-network:
    external: true
EOL
    
    # Create initialization script for multiple databases
    mkdir -p shared-db/init
    cat > shared-db/init/create-multiple-databases.sh << EOL
#!/bin/bash

# This script creates multiple databases in MariaDB

set -e
set -u

echo "Creating OpenEMR database..."
mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS openemr CHARACTER SET utf8;"
mysql -u root -proot -e "GRANT ALL ON openemr.* TO 'openemr'@'%' IDENTIFIED BY 'openemr';"

echo "Creating Telehealth database..."
mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS telehealth CHARACTER SET utf8;"
mysql -u root -proot -e "GRANT ALL ON telehealth.* TO 'telehealth'@'%' IDENTIFIED BY 'telehealth';"

echo "Creating WordPress database..."
mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS wordpress CHARACTER SET utf8;"
mysql -u root -proot -e "GRANT ALL ON wordpress.* TO 'wordpress'@'%' IDENTIFIED BY 'wordpress';"

echo "Flushing privileges..."
mysql -u root -proot -e "FLUSH PRIVILEGES;"

echo "All databases created successfully!"
EOL
    
    # Make the initialization script executable
    chmod +x shared-db/init/create-multiple-databases.sh
    
    echo "Starting shared database container..."
    cd shared-db
    $DOCKER_COMPOSE up -d
    cd ..
    
    # Wait for database to be ready
    echo "Waiting for shared database to be ready..."
    MAX_TRIES=30
    COUNTER=0
    while [ $COUNTER -lt $MAX_TRIES ]; do
        if docker exec ${PROJECT_NAME}-${ENVIRONMENT}-shared-db mysqladmin ping -h localhost -u root --password=root --silent; then
            echo "Shared database is ready!"
            break
        fi
        echo "Waiting for shared database to be ready... ($COUNTER/$MAX_TRIES)"
        sleep 5
        COUNTER=$((COUNTER+1))
    done
    
    if [ $COUNTER -eq $MAX_TRIES ]; then
        echo "Shared database did not become ready in time. Continuing anyway..."
    fi
    
    # Update OpenEMR .env file to use shared database
    if [ -f "openemr/.env" ]; then
        echo "Updating OpenEMR database configuration..."
        # Backup original .env file
        cp openemr/.env openemr/.env.bak
        # Update database host
        sed -i "s/MYSQL_HOST=.*/MYSQL_HOST=${PROJECT_NAME}-${ENVIRONMENT}-shared-db/g" openemr/.env
        # Update database name
        sed -i "s/MYSQL_DATABASE=.*/MYSQL_DATABASE=openemr/g" openemr/.env
        echo "OpenEMR configured to use shared database"
    fi
    
    # Update Telehealth .env file to use shared database
    if [ -f "telehealth/.env" ]; then
        echo "Updating Telehealth database configuration..."
        # Backup original .env file
        cp telehealth/.env telehealth/.env.bak
        # Update database configuration
        sed -i "s/DB_HOST=.*/DB_HOST=${PROJECT_NAME}-${ENVIRONMENT}-shared-db/g" telehealth/.env
        sed -i "s/DB_DATABASE=.*/DB_DATABASE=telehealth/g" telehealth/.env
        sed -i "s/DB_USERNAME=.*/DB_USERNAME=telehealth/g" telehealth/.env
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=telehealth/g" telehealth/.env
        echo "Telehealth configured to use shared database"
    fi
    
    # Update WordPress .env file to use shared database
    if [ -f "wordpress/.env" ]; then
        echo "Updating WordPress database configuration..."
        # Backup original .env file
        cp wordpress/.env wordpress/.env.bak
        # Update database configuration
        sed -i "s/WORDPRESS_DB_HOST=.*/WORDPRESS_DB_HOST=${PROJECT_NAME}-${ENVIRONMENT}-shared-db/g" wordpress/.env
        sed -i "s/WORDPRESS_DB_NAME=.*/WORDPRESS_DB_NAME=wordpress/g" wordpress/.env
        echo "WordPress configured to use shared database"
    fi
    
    echo "Shared database setup complete!"
fi

# Apply domain override if specified
if [ ! -z "$OVERRIDE_DOMAIN_BASE" ]; then
    echo "Overriding domain base: $DEFAULT_DOMAIN_BASE -> $OVERRIDE_DOMAIN_BASE"
    
    # Update domain in configuration files
    echo "Updating domain in configuration files..."
    
    # Update OpenEMR .env file
    if [ -f "openemr/.env" ]; then
        echo "Updating OpenEMR .env file..."
        # Get current domain from .env file
        CURRENT_OPENEMR_DOMAIN=$(grep "DOMAIN=" openemr/.env | cut -d= -f2)
        # Calculate new domain
        if [ "$ENVIRONMENT" = "production" ]; then
            NEW_OPENEMR_DOMAIN="$PROJECT_NAME.$OVERRIDE_DOMAIN_BASE"
        else
            NEW_OPENEMR_DOMAIN="$ENVIRONMENT-$PROJECT_NAME.$OVERRIDE_DOMAIN_BASE"
        fi
        # Replace domain in .env file
        sed -i "s|DOMAIN=$CURRENT_OPENEMR_DOMAIN|DOMAIN=$NEW_OPENEMR_DOMAIN|g" openemr/.env
        echo "  Updated OpenEMR domain: $CURRENT_OPENEMR_DOMAIN -> $NEW_OPENEMR_DOMAIN"
    fi
    
    # Update Telehealth .env file
    if [ -f "telehealth/.env" ]; then
        echo "Updating Telehealth .env file..."
        # Get current domain from .env file
        CURRENT_TELEHEALTH_DOMAIN=$(grep "DOMAIN=" telehealth/.env | cut -d= -f2)
        # Calculate new domain
        if [ "$ENVIRONMENT" = "production" ]; then
            NEW_TELEHEALTH_DOMAIN="vc.$OVERRIDE_DOMAIN_BASE"
        else
            NEW_TELEHEALTH_DOMAIN="vc-$ENVIRONMENT.$OVERRIDE_DOMAIN_BASE"
        fi
        # Replace domain in .env file
        sed -i "s|DOMAIN=$CURRENT_TELEHEALTH_DOMAIN|DOMAIN=$NEW_TELEHEALTH_DOMAIN|g" telehealth/.env
        echo "  Updated Telehealth domain: $CURRENT_TELEHEALTH_DOMAIN -> $NEW_TELEHEALTH_DOMAIN"
    fi
    
    # Update WordPress .env file if it exists
    if [ -f "wordpress/.env" ]; then
        echo "Updating WordPress .env file..."
        # Get current domain from .env file if it exists
        CURRENT_WORDPRESS_DOMAIN=$(grep "DOMAIN=" wordpress/.env | cut -d= -f2 || echo "")
        if [ ! -z "$CURRENT_WORDPRESS_DOMAIN" ]; then
            # Calculate new domain
            if [ "$ENVIRONMENT" = "production" ]; then
                NEW_WORDPRESS_DOMAIN="$OVERRIDE_DOMAIN_BASE"
            else
                NEW_WORDPRESS_DOMAIN="$ENVIRONMENT.$OVERRIDE_DOMAIN_BASE"
            fi
            # Replace domain in .env file
            sed -i "s|DOMAIN=$CURRENT_WORDPRESS_DOMAIN|DOMAIN=$NEW_WORDPRESS_DOMAIN|g" wordpress/.env
            echo "  Updated WordPress domain: $CURRENT_WORDPRESS_DOMAIN -> $NEW_WORDPRESS_DOMAIN"
        else
            # Add domain to .env file if it doesn't exist
            if [ "$ENVIRONMENT" = "production" ]; then
                echo "DOMAIN=$OVERRIDE_DOMAIN_BASE" >> wordpress/.env
                echo "  Added WordPress domain: $OVERRIDE_DOMAIN_BASE"
            else
                echo "DOMAIN=$ENVIRONMENT.$OVERRIDE_DOMAIN_BASE" >> wordpress/.env
                echo "  Added WordPress domain: $ENVIRONMENT.$OVERRIDE_DOMAIN_BASE"
            fi
        fi
    fi
    
    # Update Jitsi .env file if it exists
    if [ -f "jitsi-docker/.env" ]; then
        echo "Updating Jitsi .env file..."
        # Get current domain from .env file
        CURRENT_JITSI_DOMAIN=$(grep "DOMAIN=" jitsi-docker/.env | cut -d= -f2 || echo "")
        if [ ! -z "$CURRENT_JITSI_DOMAIN" ]; then
            # Calculate new domain
            if [ "$ENVIRONMENT" = "production" ]; then
                NEW_JITSI_DOMAIN="vcbknd.$OVERRIDE_DOMAIN_BASE"
            else
                NEW_JITSI_DOMAIN="vcbknd-$ENVIRONMENT.$OVERRIDE_DOMAIN_BASE"
            fi
            # Replace domain in .env file
            sed -i "s|DOMAIN=$CURRENT_JITSI_DOMAIN|DOMAIN=$NEW_JITSI_DOMAIN|g" jitsi-docker/.env
            echo "  Updated Jitsi domain: $CURRENT_JITSI_DOMAIN -> $NEW_JITSI_DOMAIN"
        fi
    fi
    
    echo "Domain updates complete."
    DOMAIN_BASE="$OVERRIDE_DOMAIN_BASE"
else
    DOMAIN_BASE="$DEFAULT_DOMAIN_BASE"
fi

# Set network names
# Commented out problematic proxy network
# ENV_PROXY_NETWORK="proxy-$PROJECT_NAME-$ENVIRONMENT"
ENV_FRONTEND_NETWORK="frontend-$PROJECT_NAME-$ENVIRONMENT"
SHARED_NETWORK="${PROJECT_NAME}-shared-network"
PROXY_DEFAULT_NETWORK="${PROJECT_NAME}-proxy_default"

# Set environment variables for docker-compose files
# This ensures docker-compose uses our environment-specific networks
export FRONTEND_NETWORK="$ENV_FRONTEND_NETWORK"
# Using default network instead of problematic proxy network
export PROXY_NETWORK="bridge"

echo "====================================================="
echo "Starting All-In-One Telehealth Platform Deployment"
echo "Project: $PROJECT_NAME"
echo "Environment: $ENVIRONMENT"
echo "====================================================="

# Step 1: Create required Docker networks
echo "Step 1: Creating Docker networks..."
echo "-----------------------------------"

# Commented out problematic proxy network creation
# echo "Creating environment-specific proxy network ($ENV_PROXY_NETWORK)..."
# docker network create $ENV_PROXY_NETWORK 2>/dev/null || echo "Environment-specific proxy network already exists"

# Create the environment-specific frontend network
echo "Creating environment-specific frontend network ($ENV_FRONTEND_NETWORK)..."
docker network create $ENV_FRONTEND_NETWORK 2>/dev/null || echo "Environment-specific frontend network already exists"

# Create the shared network
echo "Creating shared network ($SHARED_NETWORK)..."
docker network create $SHARED_NETWORK 2>/dev/null || echo "Shared network already exists"

# Create the default proxy network
echo "Creating proxy default network ($PROXY_DEFAULT_NETWORK)..."
docker network create $PROXY_DEFAULT_NETWORK 2>/dev/null || echo "Proxy default network already exists"

# List all created networks for verification
echo "\nVerifying created networks:"
docker network ls | grep -E "$PROJECT_NAME|proxy-$PROJECT_NAME"
echo "-----------------------------------"

# Function to run docker compose with error handling
run_docker_compose() {
    local dir=$1
    local service_name=$2
    
    echo "Starting $service_name..."
    if [ ! -d "$dir" ]; then
        echo "ERROR: Directory '$dir' does not exist!"
        return 1
    fi
    
    cd "$dir"
    echo "Running: $DOCKER_COMPOSE up -d in $(pwd)"
    
    # Check if docker-compose.yml exists
    if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
        echo "ERROR: No docker-compose.yml or docker-compose.yaml file found in $(pwd)!"
        cd ..
        return 1
    fi
    
    # Run docker compose with output capture
    output=$($DOCKER_COMPOSE up -d 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Failed to start $service_name!"
        echo "Docker Compose output:"
        echo "$output"
        cd ..
        return 1
    fi
    
    echo "Successfully started $service_name"
    cd ..
    return 0
}

# Step 2: Start NPM (Nginx Proxy Manager) first
echo "Step 2: Starting Nginx Proxy Manager..."
echo "--------------------------------------"
run_docker_compose "proxy" "Nginx Proxy Manager"
if [ $? -ne 0 ]; then
    echo "Failed to start Nginx Proxy Manager. Continuing anyway..."
fi

# Wait for NPM to be ready
echo "Waiting for NPM to be ready..."
sleep 10

# Step 3: Check if Telehealth is already set up
echo "Step 3: Checking Telehealth setup status..."
echo "-----------------------------------"

# Define container names
TELEHEALTH_APP_CONTAINER="${PROJECT_NAME}-${ENVIRONMENT}-telehealth-app-1"
TELEHEALTH_DB_CONTAINER="${PROJECT_NAME}-${ENVIRONMENT}-telehealth-database-1"

# Check if containers already exist and are running
TELEHEALTH_RUNNING=false
if docker ps --format "{{.Names}}" | grep -q "$TELEHEALTH_APP_CONTAINER"; then
    echo "Telehealth container is already running."
    TELEHEALTH_RUNNING=true
    
    # If the container is already running, assume it's already set up
    echo "Container is running, assuming it's already set up. Skipping first-time setup."
    SKIP_TELEHEALTH_SETUP=true
else
    echo "Telehealth container is not running. Will start it and perform first-time setup."
    SKIP_TELEHEALTH_SETUP=false
fi

# Step 4: Start Telehealth if not already running
if [ "$TELEHEALTH_RUNNING" = false ]; then
    echo "Step 4: Starting Telehealth..."
    echo "----------------------------"
    run_docker_compose "telehealth" "Telehealth"
    if [ $? -ne 0 ]; then
        echo "Failed to start Telehealth. Continuing anyway..."
    fi
else
    echo "Step 4: Telehealth already running, skipping startup"
fi

# Step 5: Setup Telehealth (first-time setup if needed)
echo "Step 5: Setting up Telehealth..."
echo "-----------------------------"

# We've already checked Telehealth setup status in Step 3
# The SKIP_TELEHEALTH_SETUP flag is already set

if [ "$SKIP_TELEHEALTH_SETUP" = true ]; then
    echo "Skipping Telehealth setup since container is already running and configured."
    echo "Skipping token generation as well - using existing token."
else
    # Wait for MySQL to be ready
    echo "Waiting for telehealth database to be ready..."
    MAX_TRIES=30
    COUNTER=0
    while [ $COUNTER -lt $MAX_TRIES ]; do
        if docker exec $TELEHEALTH_DB_CONTAINER mysqladmin ping -h localhost -u root --password=root --silent; then
            echo "Database is ready!"
            break
        fi
        echo "Waiting for database to be ready... ($COUNTER/$MAX_TRIES)"
        sleep 5
        COUNTER=$((COUNTER+1))
    done

    if [ $COUNTER -eq $MAX_TRIES ]; then
        echo "Database did not become ready in time. Continuing anyway..."
    fi

    # Install required PHP dependencies for Composer using root user
    echo "Installing required PHP dependencies..."
    docker exec -u 0 $TELEHEALTH_APP_CONTAINER apt-get update
    docker exec -u 0 $TELEHEALTH_APP_CONTAINER apt-get install -y zip unzip libzip-dev
    docker exec -u 0 $TELEHEALTH_APP_CONTAINER docker-php-ext-install zip

    echo "Running composer install..."
    docker exec $TELEHEALTH_APP_CONTAINER composer install --working-dir=/var/www

    echo "Generating application key..."
    docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan key:generate

    echo "Running database migrations..."
    docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan migrate --force

    echo "Running database seeding..."
    docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan db:seed --force
    
    # Generate new token for fresh setup
    echo "Generating API token..."
    RAW_TOKEN=$(docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan token:issue)
    echo "Raw token output: $RAW_TOKEN"

    # Extract just the token part - looking for the pattern that matches a token
    # Tokens are usually in the format: number|alphanumeric string
    TOKEN=$(echo "$RAW_TOKEN" | grep -o '[0-9]\+|[a-zA-Z0-9]\+' | head -n 1)

    # If we couldn't extract the token with the pattern, try the last word as fallback
    if [ -z "$TOKEN" ]; then
        echo "Could not extract token with pattern, trying last word fallback..."
        TOKEN=$(echo "$RAW_TOKEN" | awk '{print $NF}' | sed 's/\x1B\[[0-9;]*[mK]//g' | sed 's/\[39m//g')
    fi

    echo "Extracted API Token: $TOKEN"

    # Update OpenEMR's .env with the token
    OPENEMR_ENV_PATH="./openemr/.env"
    echo "Updating OpenEMR .env at: $OPENEMR_ENV_PATH"

    if [ -f "$OPENEMR_ENV_PATH" ]; then
        # Properly escape the token for sed
        ESCAPED_TOKEN=$(echo "$TOKEN" | sed 's/[\&/]/\\&/g')
        
        # Replace the token in the .env file with properly escaped token
        sed -i "s/TELEHEALTH_API_TOKEN=.*/TELEHEALTH_API_TOKEN=$ESCAPED_TOKEN/g" "$OPENEMR_ENV_PATH"
        echo "Successfully updated OpenEMR .env with new API token"
    else
        echo "OpenEMR .env file not found at: $OPENEMR_ENV_PATH"
    fi
fi

# Step 5: Start OpenEMR (after Telehealth token generation)
echo "Step 5: Starting OpenEMR..."
echo "--------------------------"
run_docker_compose "openemr" "OpenEMR"
if [ $? -ne 0 ]; then
    echo "Failed to start OpenEMR. Continuing anyway..."
fi

# Step 6: Start Jitsi (if it exists)
if [ -d "jitsi-docker" ]; then
    echo "Step 6: Starting Jitsi..."
    echo "------------------------"
    cd jitsi-docker
    $DOCKER_COMPOSE up -d
    cd ..
fi

# Step 7: Start WordPress (if it exists)
if [ -d "wordpress" ]; then
    echo "Step 7: Starting WordPress..."
    echo "----------------------------"
    cd wordpress
    $DOCKER_COMPOSE up -d
    cd ..
fi

# Step 8: Connect containers to networks
echo "Step 8: Connecting containers to networks..."
echo "------------------------------------------"

# Get container names
# More flexible container detection with multiple patterns
echo "Detecting containers with flexible patterns..."

# NPM container detection
NPM_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}.*proxy.*-1|proxy.*${PROJECT_NAME}.*-1" | head -n 1)
echo "NPM container detection result: $NPM_CONTAINER"

# OpenEMR container detection
OPENEMR_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}.*openemr.*-1|openemr.*${PROJECT_NAME}.*-1" | head -n 1)
echo "OpenEMR container detection result: $OPENEMR_CONTAINER"

# Telehealth container detection
TELEHEALTH_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}.*telehealth.*app.*-1|telehealth.*${PROJECT_NAME}.*app.*-1" | head -n 1)
echo "Telehealth container detection result: $TELEHEALTH_CONTAINER"

# WordPress container detection
WORDPRESS_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}.*wordpress.*-1|wordpress.*${PROJECT_NAME}.*-1" | head -n 1)
echo "WordPress container detection result: $WORDPRESS_CONTAINER"

# Jitsi container detection
JITSI_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}.*jitsi.*web.*-1|jitsi.*${PROJECT_NAME}.*web.*-1" | head -n 1)
echo "Jitsi container detection result: $JITSI_CONTAINER"

# Connect NPM to all networks
echo "Connecting NPM to networks..."
if [ ! -z "$NPM_CONTAINER" ]; then
    docker network connect $FRONTEND_NETWORK $NPM_CONTAINER 2>/dev/null || echo "NPM already connected to frontend network"
    docker network connect $SHARED_NETWORK $NPM_CONTAINER 2>/dev/null || echo "NPM already connected to shared network"
fi

# Connect OpenEMR to proxy network
echo "Connecting OpenEMR to networks..."
if [ ! -z "$OPENEMR_CONTAINER" ]; then
    docker network connect $PROXY_NETWORK $OPENEMR_CONTAINER 2>/dev/null || echo "OpenEMR already connected to proxy network"
    docker network connect $SHARED_NETWORK $OPENEMR_CONTAINER 2>/dev/null || echo "OpenEMR already connected to shared network"
fi

# Connect Telehealth to proxy network
echo "Connecting Telehealth to networks..."
if [ ! -z "$TELEHEALTH_CONTAINER" ]; then
    docker network connect $PROXY_NETWORK $TELEHEALTH_CONTAINER 2>/dev/null || echo "Telehealth already connected to proxy network"
    docker network connect $SHARED_NETWORK $TELEHEALTH_CONTAINER 2>/dev/null || echo "Telehealth already connected to shared network"
fi

# Connect WordPress to proxy network
echo "Connecting WordPress to networks..."
if [ ! -z "$WORDPRESS_CONTAINER" ]; then
    docker network connect $PROXY_NETWORK $WORDPRESS_CONTAINER 2>/dev/null || echo "WordPress already connected to proxy network"
fi

# Connect Jitsi to proxy network
echo "Connecting Jitsi to networks..."
if [ ! -z "$JITSI_CONTAINER" ]; then
    docker network connect $PROXY_NETWORK $JITSI_CONTAINER 2>/dev/null || echo "Jitsi already connected to proxy network"
fi

# Step 9: Configure Nginx Proxy Manager
echo "Step 9: Configuring Nginx Proxy Manager..."
echo "-----------------------------------"

# NPM API credentials
NPM_EMAIL="jmdurant@gmail.com"
NPM_PASSWORD="passtheNPM"
NPM_URL="http://localhost:${NPM_ADMIN_PORT}"

# Detect NPM container
NPM_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-.*proxy.*-1" | head -n 1)
if [ -z "$NPM_CONTAINER" ]; then
    # Try alternative naming pattern
    NPM_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "proxy.*${PROJECT_NAME}.*-1" | head -n 1)
fi

if [ -z "$NPM_CONTAINER" ]; then
    echo "Warning: Could not detect NPM container. Restart option will not work."
else
    echo "Detected NPM container: $NPM_CONTAINER"
fi

# Wait for NPM to be fully started
echo "Waiting for NPM API to be available..."
sleep 20  # Increased wait time to ensure NPM is fully initialized

# Check if NPM is responding
echo "Checking if NPM is responding at ${NPM_URL}..."
NPM_RESPONSE=$(curl -s -I ${NPM_URL})
echo "NPM response: $NPM_RESPONSE"

if [ -z "$NPM_RESPONSE" ]; then
    echo "Warning: NPM does not appear to be responding. Will try to continue anyway."
fi

# Function to authenticate with NPM API
get_npm_token() {
    echo "Authenticating with NPM API..."
    
    # Try to log in and get token
    TOKEN_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
        -H "Content-Type: application/json" \
        -d '{"identity":"'"${NPM_EMAIL}"'","secret":"'"${NPM_PASSWORD}"'"}' \
        --retry 5 --retry-delay 2)
    
    echo "Token response: $TOKEN_RESPONSE"
    
    # Extract token from response
    TOKEN=$(echo $TOKEN_RESPONSE | grep -o '"token":"[^"]*"' | cut -d\" -f4)
    
    if [ -z "$TOKEN" ]; then
        echo "Failed to authenticate with NPM API. Using default credentials..."
        # Try with default credentials
        DEFAULT_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
            -H "Content-Type: application/json" \
            -d '{"identity":"admin@example.com","secret":"changeme"}' \
            --retry 5 --retry-delay 2)
        
        echo "Default token response: $DEFAULT_RESPONSE"
        
        TOKEN=$(echo $DEFAULT_RESPONSE | grep -o '"token":"[^"]*"' | cut -d\" -f4)
    fi
    
    if [ -z "$TOKEN" ]; then
        echo "Failed to get authentication token with both custom and default credentials."
        return 1
    fi
    
    echo "Successfully obtained NPM authentication token."
    echo "$TOKEN"
}

# Function to create a proxy host
create_proxy_host() {
    local TOKEN=$1
    local DOMAIN=$2
    local FORWARD_HOST=$3
    local FORWARD_PORT=$4
    local WEBSOCKET=${5:-false}
    
    echo "Creating proxy host for domain: $DOMAIN -> $FORWARD_HOST:$FORWARD_PORT"
    
    if [ -z "$TOKEN" ]; then
        echo "Error: No authentication token provided. Cannot create proxy host."
        return 1
    fi
    
    # Check if proxy host already exists
    echo "Checking if proxy host already exists..."
    EXISTING=$(curl -v -s -X GET "${NPM_URL}/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer $TOKEN" 2>&1)
    
    echo "Existing hosts response: $EXISTING"
    
    # More robust check for existing domain
    if echo "$EXISTING" | grep -q "$DOMAIN"; then
        echo "Proxy host for $DOMAIN already exists. Skipping."
        return 0
    fi
    
    # Create the JSON payload - EXACTLY matching PowerShell script's basic configuration
    PAYLOAD='{
        "domain_names": ["'"$DOMAIN"'"],
        "forward_host": "'"$FORWARD_HOST"'",
        "forward_port": '$FORWARD_PORT',
        "forward_scheme": "http",
        "block_exploits": true,
        "allow_websocket_upgrade": '$WEBSOCKET'
    }'
    
    echo "Creating proxy host with payload: $PAYLOAD"
    
    # Create proxy host with verbose output
    RESPONSE=$(curl -v -s -X POST "${NPM_URL}/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1)
    
    echo "Create proxy host response: $RESPONSE"
    
    if echo "$RESPONSE" | grep -q "id"; then
        echo "Successfully created proxy host for $DOMAIN"
        return 0
    else
        echo "Failed to create proxy host for $DOMAIN"
        echo "Response: $RESPONSE"
        return 1
    fi
}

# Get NPM authentication token
NPM_TOKEN=$(get_npm_token)

if [ -z "$NPM_TOKEN" ]; then
    echo "Failed to authenticate with NPM API. Proxy hosts will not be configured."
else
    echo "Successfully authenticated with NPM API."
    
    # Debug: Show current domain base
    echo "Current DOMAIN_BASE: $DOMAIN_BASE"
    echo "Current PROJECT_NAME: $PROJECT_NAME"
    echo "Current DISPLAY_NAME: $DISPLAY_NAME"
    echo "Current ENVIRONMENT: $ENVIRONMENT"
    
    # Set domain names based on environment and domain base
    if [ "$ENVIRONMENT" = "production" ]; then
        # For production, WordPress is at the root domain, other services at subdomains
        OPENEMR_DOMAIN="$DISPLAY_NAME.$DOMAIN_BASE"
        TELEHEALTH_DOMAIN="vc.$DOMAIN_BASE"
        JITSI_DOMAIN="vcbknd.$DOMAIN_BASE"
        WORDPRESS_DOMAIN="$DOMAIN_BASE"
    else
        # For non-production environments, all services at environment-specific subdomains
        OPENEMR_DOMAIN="$ENVIRONMENT-$DISPLAY_NAME.$DOMAIN_BASE"
        TELEHEALTH_DOMAIN="vc-$ENVIRONMENT.$DOMAIN_BASE"
        JITSI_DOMAIN="vcbknd-$ENVIRONMENT.$DOMAIN_BASE"
        WORDPRESS_DOMAIN="$ENVIRONMENT.$DOMAIN_BASE"
    fi
    
    # Debug: Show configured domains
    echo "Configured domains:"
    echo "- OpenEMR: $OPENEMR_DOMAIN"
    echo "- Telehealth: $TELEHEALTH_DOMAIN"
    echo "- Jitsi: $JITSI_DOMAIN"
    echo "- WordPress: $WORDPRESS_DOMAIN"
    
    # Debug: Show detected containers
    echo "Detected containers:"
    echo "- OpenEMR: $OPENEMR_CONTAINER"
    echo "- Telehealth: $TELEHEALTH_CONTAINER"
    echo "- Jitsi: $JITSI_CONTAINER"
    echo "- WordPress: $WORDPRESS_CONTAINER"
    
    # Create proxy hosts for each service
    if [ ! -z "$OPENEMR_CONTAINER" ]; then
        echo ""
        echo "Creating OpenEMR proxy host..."
        create_proxy_host "$NPM_TOKEN" "$OPENEMR_DOMAIN" "$OPENEMR_CONTAINER" 80 false
        echo "OpenEMR proxy host creation completed."
    else
        echo "OpenEMR container not detected, skipping proxy host creation."
    fi
    
    if [ ! -z "$TELEHEALTH_CONTAINER" ]; then
        echo ""
        echo "Creating Telehealth proxy host..."
        create_proxy_host "$NPM_TOKEN" "$TELEHEALTH_DOMAIN" "$TELEHEALTH_CONTAINER" 80 false
        echo "Telehealth proxy host creation completed."
    else
        echo "Telehealth container not detected, skipping proxy host creation."
    fi
    
    if [ ! -z "$JITSI_CONTAINER" ]; then
        echo ""
        echo "Creating Jitsi proxy host..."
        create_proxy_host "$NPM_TOKEN" "$JITSI_DOMAIN" "$JITSI_CONTAINER" 80 true
        echo "Jitsi proxy host creation completed."
    else
        echo "Jitsi container not detected, skipping proxy host creation."
    fi
    
    if [ ! -z "$WORDPRESS_CONTAINER" ]; then
        echo ""
        echo "Creating WordPress proxy host..."
        create_proxy_host "$NPM_TOKEN" "$WORDPRESS_DOMAIN" "$WORDPRESS_CONTAINER" 80 false
        echo "WordPress proxy host creation completed."
    else
        echo "WordPress container not detected, skipping proxy host creation."
    fi
    
    echo ""
    echo "NPM proxy hosts configuration complete!"
    
    # Check if NPM restart was requested
    if [ "$RESTART_NPM" = true ]; then
        if [ ! -z "$NPM_CONTAINER" ]; then
            echo "Restarting NPM container as requested with --restart-npm flag..."
            docker restart $NPM_CONTAINER
            echo "Waiting 20 seconds for NPM to initialize after restart..."
            sleep 20
            echo "NPM container restarted. New configuration will be applied."
        else
            echo "Warning: Cannot restart NPM container because it was not detected."
        fi
    else
        echo "NPM restart not requested. Use --restart-npm flag if needed."
    fi
fi

# Step 9: Display access information
echo "Step 9: Setup Complete"
echo "-------------------"
echo "The All-In-One Telehealth Platform deployment is complete!"
echo ""
echo "Access Information:"
echo "- OpenEMR Direct: http://localhost:$(grep HTTP_PORT openemr/.env | cut -d= -f2)"
echo "- OpenEMR via NPM: https://$OPENEMR_DOMAIN"
echo "- Telehealth via NPM: https://$TELEHEALTH_DOMAIN"
echo "- Jitsi via NPM: https://$JITSI_DOMAIN"
echo "- WordPress Direct: http://localhost:$(grep HTTP_PORT wordpress/.env | cut -d= -f2 || echo "33080")"
echo "- WordPress via NPM: https://$WORDPRESS_DOMAIN"
echo "- Nginx Proxy Manager Admin: http://localhost:$NPM_ADMIN_PORT"
echo ""
echo "Important notes:"
echo "- Default NPM login: admin@example.com / changeme"
echo "- Default OpenEMR login: admin / AdminOps2023**"
echo "- Add the following entries to your /etc/hosts file (or DNS):"
echo "  <YOUR_SERVER_IP> $OPENEMR_DOMAIN $TELEHEALTH_DOMAIN $JITSI_DOMAIN $WORDPRESS_DOMAIN"
echo ""
echo "Thank you for using the All-In-One Telehealth Platform!"

# End of script
