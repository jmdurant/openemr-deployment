#!/bin/bash
# Simple Deployment Startup Script for All-In-One Telehealth Platform
# This script starts all components assuming they are already configured

# Set strict error handling
set -e

# Default values for key variables
PROJECT_NAME="official"
ENVIRONMENT="production"
DOMAIN_BASE="localhost"
ZIP_FILE=""
EXTRACT_DIR=""
SKIP_EXTRACT=false

# Parse command line arguments
RESET=false
PURGE=false
STOP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET=true
      shift
      ;;
    --stop)
      STOP=true
      shift
      ;;
    --purge)
      PURGE=true
      shift
      ;;
    --project=*)
      PROJECT_NAME="${1#*=}"
      shift
      ;;
    --environment=*)
      ENVIRONMENT="${1#*=}"
      shift
      ;;
    --domainbase=*)
      DOMAIN_BASE="${1#*=}"
      shift
      ;;
    --zipfile=*)
      ZIP_FILE="${1#*=}"
      shift
      ;;
    --extractdir=*)
      EXTRACT_DIR="${1#*=}"
      shift
      ;;
    --skip-extract)
      SKIP_EXTRACT=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--reset] [--stop] [--purge] [--project=NAME] [--environment=ENV] [--domainbase=DOMAIN] [--zipfile=FILE] [--extractdir=DIR] [--skip-extract]"
      echo "  --reset               Stop all containers, remove volumes, and delete networks"
      echo "  --stop                Stop all project containers without removing volumes or networks"
      echo "  --purge               Perform a complete Docker system prune"
      echo "  --project=NAME        Set the project name (default: official)"
      echo "  --environment=ENV     Set the environment (default: production)"
      echo "  --domainbase=DOMAIN   Set the domain base (default: localhost)"
      echo "  --zipfile=FILE        Deployment zip file to extract before starting"
      echo "  --extractdir=DIR      Directory to extract the zip file to (default: current directory)"
      echo "  --skip-extract        Skip extraction even if zipfile is provided"
      exit 1
      ;;
  esac
done

# Display the configuration
echo "Configuration:"
echo "- Project Name: $PROJECT_NAME"
echo "- Environment: $ENVIRONMENT"
echo "- Domain Base: $DOMAIN_BASE"

# Handle zip file extraction if provided
if [ -n "$ZIP_FILE" ] && [ "$SKIP_EXTRACT" = false ]; then
  echo "================================================="
  echo "EXTRACTING DEPLOYMENT PACKAGE"
  echo "================================================="
  
  # Check if the zip file exists
  if [ ! -f "$ZIP_FILE" ]; then
    echo "Error: Zip file '$ZIP_FILE' not found."
    exit 1
  fi
  
  echo "Extracting deployment package: $ZIP_FILE"
  
  # Determine extraction directory
  if [ -z "$EXTRACT_DIR" ]; then
    # If no extraction directory is specified, use the current directory
    EXTRACT_DIR="."
  fi
  
  # Create extraction directory if it doesn't exist
  mkdir -p "$EXTRACT_DIR"
  
  # Extract the zip file
  unzip -o "$ZIP_FILE" -d "$EXTRACT_DIR"
  
  # If extraction directory is not the current directory, change to it
  if [ "$EXTRACT_DIR" != "." ]; then
    echo "Changing to extraction directory: $EXTRACT_DIR"
    cd "$EXTRACT_DIR"
  fi
  
  echo "Extraction completed successfully."
  echo "================================================="
fi

# Function to reset the deployment (stop containers, remove volumes, delete networks)
reset_deployment() {
  echo "=================================================="
  echo "RESETTING DEPLOYMENT"
  echo "This will stop all containers, remove volumes, and delete networks"
  echo "=================================================="
  
  # Stop all running containers
  echo "Stopping all running containers..."
  docker ps -q | xargs -r docker stop
  
  # Remove all containers
  echo "Removing all containers..."
  docker ps -a -q | xargs -r docker rm -f
  
  # Remove all volumes
  echo "Removing all volumes..."
  docker volume ls -q | xargs -r docker volume rm
  
  # Remove all networks (except default ones)
  echo "Removing all custom networks..."
  docker network ls --filter "type=custom" -q | xargs -r docker network rm
  
  echo "Reset complete. All containers, volumes, and networks have been removed."
  echo "=================================================="
}

# Function to stop project containers without removing volumes or networks
stop_containers() {
  echo "=================================================="
  echo "STOPPING PROJECT CONTAINERS"
  echo "This will stop all project containers but preserve volumes and networks"
  echo "=================================================="
  
  # Stop containers related to this project
  echo "Stopping containers for project ${PROJECT_NAME}..."
  docker ps --format '{{.Names}}' | grep "${PROJECT_NAME}" | xargs -r docker stop
  
  # Stop Jitsi containers (they might have different naming patterns)
  jitsi_containers=$(docker ps --format '{{.Names}}' | grep -E "jitsi|jvb|jicofo|prosody|web")
  if [ -n "$jitsi_containers" ]; then
    echo "Stopping Jitsi containers:"
    echo "$jitsi_containers"
    echo "$jitsi_containers" | xargs -r docker stop
  fi
  
  # Also stop NPM container if it exists
  npm_container=$(docker ps --format '{{.Names}}' | grep -E "npm.*-1" | head -1)
  if [ -n "$npm_container" ]; then
    echo "Stopping NPM container: $npm_container"
    docker stop "$npm_container"
  fi
  
  echo "All project containers have been stopped. Volumes and networks are preserved."
  echo "=================================================="
}

# Function to perform a complete Docker system purge
purge_docker_system() {
  echo "=================================================="
  echo "PURGING DOCKER SYSTEM"
  echo "This will remove all unused containers, networks, images, and volumes"
  echo "=================================================="
  
  # Perform a complete system prune with volumes
  echo "Performing Docker system prune..."
  docker system prune -a -f --volumes
  
  echo "Docker system purge complete."
  echo "=================================================="
}

# Run reset if requested
if [ "$RESET" = true ]; then
  reset_deployment
  echo "Reset completed. Exiting as requested."
  exit 0
fi

# Run stop if requested
if [ "$STOP" = true ]; then
  stop_containers
  echo "Containers stopped. Continuing with deployment..."
fi

# Run purge if requested
if [ "$PURGE" = true ]; then
  purge_docker_system
  echo "Purge completed. Continuing with deployment..."
fi

# Display banner
echo "=================================================="
echo "STARTING DEPLOYMENT"
echo "Simple deployment script - using pre-configured files"
echo "=================================================="

# Function to check if Docker is installed and running
check_docker() {
  if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
  fi
  
  if ! docker info &> /dev/null; then
    echo "Docker daemon is not running. Please start Docker."
    exit 1
  fi
  
  # Check if docker-compose is available (either as docker-compose or docker compose)
  if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
  else
    DOCKER_COMPOSE="docker compose"
  fi
  
  echo "Using Docker Compose command: $DOCKER_COMPOSE"
}

# Function to start a service
start_service() {
  local service_dir=$1
  local service_name=$2
  
  if [ -d "$service_dir" ]; then
    echo "Starting $service_name service..."
    cd "$service_dir"
    
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
      $DOCKER_COMPOSE up -d
      echo "$service_name service started successfully."
    else
      echo "Warning: No docker-compose.yml found in $service_dir"
    fi
    
    cd ..
  else
    echo "Warning: $service_dir directory not found. Skipping $service_name service."
  fi
}

# Function to display network connection information
display_network_info() {
  echo "=================================================="
  echo "NETWORK CONNECTION INFORMATION"
  echo "=================================================="
  
  # List all networks
  echo "Available networks:"
  docker network ls
  echo ""
  
  # Check each important network using our variables
  echo "Containers connected to $FRONTEND_NETWORK network:"
  docker network inspect $FRONTEND_NETWORK --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "Network not found or no containers connected"
  echo ""
  
  echo "Containers connected to $PROXY_NETWORK network:"
  docker network inspect $PROXY_NETWORK --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "Network not found or no containers connected"
  echo ""
  
  echo "Containers connected to $SHARED_NETWORK network:"
  docker network inspect $SHARED_NETWORK --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "Network not found or no containers connected"
  echo ""
  
  # Also check for project-specific networks created by docker-compose
  echo "Project-specific networks created by docker-compose:"
  docker network ls --filter "name=${PROJECT_NAME}" | grep -v "$FRONTEND_NETWORK\|$PROXY_NETWORK\|$SHARED_NETWORK"
  echo ""
}

# Function to recreate Let's Encrypt symlinks
recreate_letsencrypt_symlinks() {
  echo "================================================="
  echo "CHECKING AND RECREATING LET'S ENCRYPT SYMLINKS"
  echo "================================================="
  
  # Check if proxy/letsencrypt directory exists
  if [ -d "proxy/letsencrypt" ]; then
    echo "Found Let's Encrypt directory."
    
    # Check if archive directory exists
    if [ -d "proxy/letsencrypt/archive" ]; then
      echo "Found archive directory. Checking for certificate directories..."
      
      # Look for npm-* directories in the archive folder
      for cert_dir in proxy/letsencrypt/archive/npm-*; do
        if [ -d "$cert_dir" ]; then
          # Extract the npm-X name from the path
          npm_name=$(basename "$cert_dir")
          echo "Found certificate directory: $npm_name"
          
          # Create the live directory if it doesn't exist
          live_dir="proxy/letsencrypt/live/$npm_name"
          mkdir -p "$live_dir"
          
          # Recreate the symlinks for each certificate file
          for cert_file in privkey.pem fullchain.pem chain.pem cert.pem; do
            if [ -f "$cert_dir/$cert_file" ]; then
              echo "Creating symlink for $cert_file in $npm_name"
              ln -sf "../../archive/$npm_name/$cert_file" "$live_dir/$cert_file"
            fi
          done
          
          echo "Symlinks recreated for $npm_name"
        fi
      done
    else
      echo "No archive directory found. Skipping symlink recreation."
    fi
  else
    echo "Let's Encrypt directory not found. Skipping symlink recreation."
  fi
  
  echo "Let's Encrypt symlink check/recreation completed."
  echo "================================================="
}

# Check Docker installation
check_docker

# Recreate Let's Encrypt symlinks before starting containers
recreate_letsencrypt_symlinks

# Create necessary Docker networks
echo "Creating Docker networks..."

# Function to create a network if it doesn't exist
create_network() {
  local network_name=$1
  if docker network inspect $network_name >/dev/null 2>&1; then
    echo "- $network_name: already exists"
  else
    docker network create $network_name >/dev/null
    echo "- $network_name: created successfully"
  fi
}

# Variables PROJECT_NAME, ENVIRONMENT, and DOMAIN_BASE are now set from command-line arguments

# Define domain names based on environment and project
# For production, use different naming convention
DISPLAY_NAME="notes"  # Use notes instead of official for OpenEMR

if [ "$ENVIRONMENT" = "production" ]; then
  # Production environment has no prefix
  OPENEMR_DOMAIN="$DISPLAY_NAME.$DOMAIN_BASE"
  TELEHEALTH_DOMAIN="vc.$DOMAIN_BASE"
  JITSI_DOMAIN="vcbknd.$DOMAIN_BASE"
  WORDPRESS_DOMAIN="$DOMAIN_BASE"
  NPM_DOMAIN="npm.$DOMAIN_BASE"
else
  # Non-production environments include the environment prefix
  PREFIX="${ENVIRONMENT,,}" # Convert to lowercase
  OPENEMR_DOMAIN="$PREFIX-$DISPLAY_NAME.$DOMAIN_BASE"
  TELEHEALTH_DOMAIN="vc-$PREFIX.$DOMAIN_BASE"
  JITSI_DOMAIN="vcbknd-$PREFIX.$DOMAIN_BASE"
  WORDPRESS_DOMAIN="$PREFIX-$PROJECT_NAME.$DOMAIN_BASE"
  NPM_DOMAIN="npm-$PREFIX.$DOMAIN_BASE"
fi
extract_ports() {
  echo "Extracting port mappings from deployed environment..."
  
  # Initialize port variables without defaults
  NPM_ADMIN_PORT="NOT_FOUND"
  OPENEMR_PORT="NOT_FOUND"
  TELEHEALTH_PORT="NOT_FOUND"
  JITSI_PORT="NOT_FOUND"
  WORDPRESS_PORT="NOT_FOUND"
  
  # First try to extract from running containers (most reliable)
  echo "Checking running containers for port mappings..."
  
  # Extract NPM admin port from running container - try multiple patterns
  NPM_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "(npm|proxy|nginx-proxy-manager)" | head -1)
  if [ -n "$NPM_CONTAINER" ]; then
    echo "Found NPM container: $NPM_CONTAINER"
    # Try to get port mapping for 81 (admin port)
    EXTRACTED_NPM_PORT=$(docker port $NPM_CONTAINER 2>/dev/null | grep '81/tcp' | head -1 | cut -d ':' -f2 || echo "")
    if [ -n "$EXTRACTED_NPM_PORT" ]; then
      echo "- Found NPM admin port from container: $EXTRACTED_NPM_PORT"
      NPM_ADMIN_PORT=$EXTRACTED_NPM_PORT
    else
      echo "- NPM admin port not found in container"
    fi
  else
    echo "- No NPM container found"
  fi
  
  # Extract OpenEMR port from running container
  OPENEMR_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "${PROJECT_NAME}.*openemr" | head -1)
  if [ -n "$OPENEMR_CONTAINER" ]; then
    # Get all port mappings and take the first one
    EXTRACTED_OPENEMR_PORT=$(docker port $OPENEMR_CONTAINER 2>/dev/null | head -1 | cut -d ':' -f2 || echo "")
    if [ -n "$EXTRACTED_OPENEMR_PORT" ]; then
      echo "- Found OpenEMR port from container: $EXTRACTED_OPENEMR_PORT"
      OPENEMR_PORT=$EXTRACTED_OPENEMR_PORT
    fi
  fi
  
  # Extract Telehealth port from running container
  TELEHEALTH_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "${PROJECT_NAME}.*telehealth" | head -1)
  if [ -n "$TELEHEALTH_CONTAINER" ]; then
    # Get all port mappings and take the first one
    EXTRACTED_TELEHEALTH_PORT=$(docker port $TELEHEALTH_CONTAINER 2>/dev/null | head -1 | cut -d ':' -f2 || echo "")
    if [ -n "$EXTRACTED_TELEHEALTH_PORT" ]; then
      echo "- Found Telehealth port from container: $EXTRACTED_TELEHEALTH_PORT"
      TELEHEALTH_PORT=$EXTRACTED_TELEHEALTH_PORT
    fi
  fi
  
  # Extract Jitsi port from running container
  JITSI_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "jitsi-docker" | head -1)
  if [ -n "$JITSI_CONTAINER" ]; then
    # Get all port mappings and take the first one
    EXTRACTED_JITSI_PORT=$(docker port $JITSI_CONTAINER 2>/dev/null | head -1 | cut -d ':' -f2 || echo "")
    if [ -n "$EXTRACTED_JITSI_PORT" ]; then
      echo "- Found Jitsi port from container: $EXTRACTED_JITSI_PORT"
      JITSI_PORT=$EXTRACTED_JITSI_PORT
    fi
  fi
  
  # Extract WordPress port from running container
  WORDPRESS_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "${PROJECT_NAME}.*wordpress" | head -1)
  if [ -n "$WORDPRESS_CONTAINER" ]; then
    # Get all port mappings and take the first one
    EXTRACTED_WP_PORT=$(docker port $WORDPRESS_CONTAINER 2>/dev/null | head -1 | cut -d ':' -f2 || echo "")
    if [ -n "$EXTRACTED_WP_PORT" ]; then
      echo "- Found WordPress port from container: $EXTRACTED_WP_PORT"
      WORDPRESS_PORT=$EXTRACTED_WP_PORT
    fi
  fi
  
  # If containers aren't running, fall back to .env files
  echo "Checking .env files for port mappings..."
  
  # Extract NPM admin port from docker-compose file
  if [ -d "proxy" ] && [ -f "proxy/docker-compose.yml" ]; then
    EXTRACTED_NPM_PORT=$(grep -A 5 'admin:' proxy/docker-compose.yml | grep -oP '(?<=:)\d+(?=:81)' || echo "")
    if [ -n "$EXTRACTED_NPM_PORT" ]; then
      echo "- Found NPM admin port from docker-compose: $EXTRACTED_NPM_PORT"
      NPM_ADMIN_PORT=$EXTRACTED_NPM_PORT
    fi
  fi
  
  # Extract OpenEMR port from .env file
  if [ -d "openemr" ] && [ -f "openemr/.env" ]; then
    echo "Found openemr/.env file"
    EXTRACTED_OPENEMR_PORT=$(grep 'HTTP_PORT=' openemr/.env | cut -d '=' -f2 | tr -d '\r\n' || echo "")
    if [ -n "$EXTRACTED_OPENEMR_PORT" ]; then
      echo "- Found OpenEMR port from .env: $EXTRACTED_OPENEMR_PORT"
      OPENEMR_PORT=$EXTRACTED_OPENEMR_PORT
    else
      echo "- HTTP_PORT not found in openemr/.env"
    fi
  else
    echo "- openemr/.env file not found"
  fi
  
  # Extract Telehealth port from .env file
  if [ -d "telehealth" ] && [ -f "telehealth/.env" ]; then
    echo "Found telehealth/.env file"
    EXTRACTED_TELEHEALTH_PORT=$(grep 'WEB_LISTEN_PORT=' telehealth/.env | cut -d '=' -f2 | tr -d '\r\n' || echo "")
    if [ -n "$EXTRACTED_TELEHEALTH_PORT" ]; then
      echo "- Found Telehealth port from .env: $EXTRACTED_TELEHEALTH_PORT"
      TELEHEALTH_PORT=$EXTRACTED_TELEHEALTH_PORT
    else
      echo "- WEB_LISTEN_PORT not found in telehealth/.env"
    fi
  else
    echo "- telehealth/.env file not found"
  fi
  
  # Extract Jitsi port from .env file
  if [ -d "jitsi-docker" ] && [ -f "jitsi-docker/.env" ]; then
    echo "Found jitsi-docker/.env file"
    # Look for HTTP_PORT specifically
    EXTRACTED_JITSI_PORT=$(grep "HTTP_PORT=" jitsi-docker/.env | cut -d '=' -f2 | tr -d '\r\n' || echo "")
    if [ -n "$EXTRACTED_JITSI_PORT" ]; then
      echo "- Found Jitsi port from .env (HTTP_PORT): $EXTRACTED_JITSI_PORT"
      JITSI_PORT=$EXTRACTED_JITSI_PORT
    else
      echo "- HTTP_PORT not found in jitsi-docker/.env"
    fi
  else
    echo "- jitsi-docker/.env file not found"
  fi
  
  # Extract WordPress port from .env file
  if [ -d "wordpress" ] && [ -f "wordpress/.env" ]; then
    echo "Found wordpress/.env file"
    EXTRACTED_WP_PORT=$(grep 'HTTP_PORT=' wordpress/.env | cut -d '=' -f2 | tr -d '\r\n' || echo "")
    if [ -n "$EXTRACTED_WP_PORT" ]; then
      echo "- Found WordPress port from .env: $EXTRACTED_WP_PORT"
      WORDPRESS_PORT=$EXTRACTED_WP_PORT
    else
      echo "- HTTP_PORT not found in wordpress/.env"
    fi
  else
    echo "- wordpress/.env file not found"
  fi
  
  echo "Port extraction complete. Using the following ports:"
  echo "- NPM Admin: $NPM_ADMIN_PORT"
  echo "- OpenEMR: $OPENEMR_PORT"
  echo "- Telehealth: $TELEHEALTH_PORT"
  echo "- Jitsi: $JITSI_PORT"
  echo "- WordPress: $WORDPRESS_PORT"
}

# Extract port information from the environment
extract_ports

# Define network names using variables
FRONTEND_NETWORK="frontend-${PROJECT_NAME}-${ENVIRONMENT}"
PROXY_NETWORK="proxy-${PROJECT_NAME}-${ENVIRONMENT}"
SHARED_NETWORK="${PROJECT_NAME}-shared-network"

# Project and environment specific networks
# Based on the memory about network naming issues
create_network "$PROXY_NETWORK"
create_network "$FRONTEND_NETWORK"
create_network "$SHARED_NETWORK"

echo "Docker networks setup complete."

# Step 1: Start Nginx Proxy Manager (NPM) first
echo "Step 1: Starting Nginx Proxy Manager..."
start_service "proxy" "Nginx Proxy Manager"

# Step 2: Start Jitsi Docker service
echo "Step 2: Starting Jitsi Docker service..."
if [ -d "jitsi-docker" ]; then
  echo "Found jitsi-docker directory, starting containers..."
  cd jitsi-docker
  if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    # Check if we need to modify the docker-compose file for network configuration
    if grep -q "frontend" docker-compose.yml; then
      echo "Docker Compose file references 'frontend' network. Applying fix..."
      # Create a backup of the original file
      cp docker-compose.yml docker-compose.yml.bak
      
      # Replace the network name 'frontend' with our specific network name
      sed -i "s/name: frontend/name: $FRONTEND_NETWORK/g" docker-compose.yml
      sed -i "s/frontend:/$FRONTEND_NETWORK:/g" docker-compose.yml
      
      echo "Modified docker-compose.yml to use our frontend network"
    fi
    
    # Start the containers
    $DOCKER_COMPOSE up -d
    echo "Jitsi Docker service started successfully."
    
    # Restore original file
    if [ -f "docker-compose.yml.bak" ]; then
      mv docker-compose.yml.bak docker-compose.yml
      echo "Restored original docker-compose.yml"
    fi
  else
    echo "Warning: No docker-compose.yml found in jitsi-docker"
  fi
  cd ..
else
  echo "Warning: jitsi-docker directory not found. Skipping Jitsi service."
fi

# Step 3: Start Telehealth service
echo "Step 3: Starting Telehealth service..."

# Handle Telehealth service
if [ -d "telehealth" ] && [ -f "telehealth/docker-compose.yml" ]; then
  echo "Setting up Telehealth service..."
  cd telehealth
  
  # Create a clean environment file with the correct network name
  if [ -f ".env" ]; then
    # Backup the original .env file
    cp .env .env.bak
    
    # Remove any existing FRONTEND_NETWORK variable
    grep -v "FRONTEND_NETWORK=" .env > .env.tmp
    mv .env.tmp .env
  fi
  
  # Add the FRONTEND_NETWORK variable to the .env file
  echo "FRONTEND_NETWORK=$FRONTEND_NETWORK" >> .env
  echo "Added FRONTEND_NETWORK=$FRONTEND_NETWORK to .env file"
  
  # Create a clean version of docker-compose.yml
  if [ -f "docker-compose.yml.original" ]; then
    # If we have an original backup, use it
    cp docker-compose.yml.original docker-compose.yml
  else
    # Otherwise, create a backup of the current file
    cp docker-compose.yml docker-compose.yml.original
  fi
  
  # Instead of modifying the docker-compose.yml file, we'll create a docker-compose.override.yml
  # This will define the frontend network explicitly
  cat > docker-compose.override.yml << EOL
version: '3'

networks:
  frontend:
    external: true
    name: $FRONTEND_NETWORK
EOL
  
  echo "Created docker-compose.override.yml with correct network configuration"
  
  echo "Modified docker-compose.yml to use environment variable for frontend network"
  
  # Check if this is a first-time setup
  TELEHEALTH_WEB_CONTAINER="${PROJECT_NAME}-${ENVIRONMENT}-telehealth-web-1"
  FIRST_TIME_SETUP=false
  
  if ! docker ps -a --format '{{.Names}}' | grep -q "$TELEHEALTH_WEB_CONTAINER"; then
    echo "First-time Telehealth setup detected."
    FIRST_TIME_SETUP=true
  fi
  
  # Start the Telehealth service
  if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    $DOCKER_COMPOSE up -d
    echo "Telehealth service started successfully."
    
    # Run first-time setup if needed
    if [ "$FIRST_TIME_SETUP" = true ]; then
      echo "First-time Telehealth setup detected. Running setup commands..."
      
      # Wait for database to be ready
      echo "Waiting for Telehealth database to be ready..."
      TELEHEALTH_DB_CONTAINER="${PROJECT_NAME}-${ENVIRONMENT}-telehealth-database-1"
      until docker exec $TELEHEALTH_DB_CONTAINER mysqladmin ping -h localhost --silent; do
        echo "Waiting for MySQL to be ready..."
        sleep 2
      done
      
      # Get the app container name
      TELEHEALTH_APP_CONTAINER="${PROJECT_NAME}-${ENVIRONMENT}-telehealth-app-1"
      
      # Install required dependencies for Composer using root user
      echo "Installing required PHP dependencies..."
      docker exec -u 0 $TELEHEALTH_APP_CONTAINER apt-get update
      docker exec -u 0 $TELEHEALTH_APP_CONTAINER apt-get install -y zip unzip libzip-dev
      docker exec -u 0 $TELEHEALTH_APP_CONTAINER docker-php-ext-install zip
      
      # Run composer install
      echo "Running composer install..."
      docker exec $TELEHEALTH_APP_CONTAINER composer install --working-dir=/var/www
      
      # Generate application key
      echo "Generating application key..."
      docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan key:generate
      
      # Run database migrations
      echo "Running database migrations..."
      docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan migrate --force
      
      # Run database seeding
      echo "Running database seeding..."
      docker exec $TELEHEALTH_APP_CONTAINER php /var/www/artisan db:seed --force
      
      # Generate API token
      echo "Generating API token..."
      
      # Capture the token by grabbing the line after the success message
      API_TOKEN=$(docker exec -i $TELEHEALTH_APP_CONTAINER bash -c "echo 'yes' | php /var/www/artisan token:issue" | grep -A1 "New token issued successfully" | tail -n1 | xargs)
      echo "API Token: $API_TOKEN"
      
      # Update OpenEMR's .env with the token
      if [ -d "../openemr" ] && [ -f "../openemr/.env" ]; then
        echo "Updating OpenEMR .env with the API token..."
        cd ../openemr
        if grep -q "TELEHEALTH_API_TOKEN=" .env; then
          # Replace existing token
          sed -i "s/TELEHEALTH_API_TOKEN=.*/TELEHEALTH_API_TOKEN=$API_TOKEN/g" .env
        else
          # Add token if it doesn't exist
          echo "TELEHEALTH_API_TOKEN=$API_TOKEN" >> .env
        fi
        cd ../telehealth
        echo "OpenEMR .env updated with API token."
      else
        echo "Warning: OpenEMR .env file not found. Please manually add the API token."
      fi
      
      echo "Telehealth first-time setup completed successfully."
    fi
  else
    echo "Warning: No docker-compose.yml found in telehealth"
  fi
  
  # We're now using environment variables instead of restoring the original file
  # This ensures the network names don't get concatenated with multiple runs
  
  cd ..
else
  # Fall back to the original method if we can't find the docker-compose.yml
  start_service "telehealth" "Telehealth"
fi

# Step 4: Start OpenEMR service
echo "Step 4: Starting OpenEMR service..."
start_service "openemr" "OpenEMR"

# Step 5: Start WordPress service (if exists)
echo "Step 5: Starting WordPress service (if exists)..."
start_service "wordpress" "WordPress"

# Step 6: Connect containers to the proxy network
echo "Step 6: Connecting containers to the proxy network..."

# Function to connect a container to a network if it's not already connected
connect_to_network() {
  local container=$1
  local network=$2
  
  # Check if container exists
  if docker ps -a --format '{{.Names}}' | grep -q "$container"; then
    echo "Found container: $container"
    
    # Check if container is already connected to the network
    if docker network inspect $network --format '{{range .Containers}}{{.Name}}{{end}}' | grep -q "$container"; then
      echo "Container $container is already connected to network $network"
    else
      echo "Connecting container $container to network $network"
      docker network connect $network $container
      echo "Connected $container to $network"
    fi
  else
    echo "Container $container not found"
  fi
}

# Connect proxy container to proxy network
proxy_container=$(docker ps --format '{{.Names}}' | grep -E "${PROJECT_NAME}.*proxy.*-1" | head -1)
if [ -n "$proxy_container" ]; then
  connect_to_network "$proxy_container" "$PROXY_NETWORK"
else
  echo "Proxy container not found"
fi

# Connect WordPress container to proxy network
wordpress_container=$(docker ps --format '{{.Names}}' | grep -E "${PROJECT_NAME}.*wordpress.*-1" | head -1)
if [ -n "$wordpress_container" ]; then
  connect_to_network "$wordpress_container" "$PROXY_NETWORK"
else
  echo "WordPress container not found"
fi

# Display success message
echo "=================================================="
echo "DEPLOYMENT COMPLETE"
echo "All services have been started."
echo "=================================================="

# Display access information
echo "Access Information:"

# NPM-based access (HTTPS)
echo "=== Access via Nginx Proxy Manager (HTTPS) ==="
echo "- OpenEMR: https://${OPENEMR_DOMAIN}"
echo "- Telehealth: https://${TELEHEALTH_DOMAIN}"
echo "- WordPress: https://${WORDPRESS_DOMAIN}"
echo "- Jitsi: https://${JITSI_DOMAIN}"
echo "- NPM Admin: http://${NPM_DOMAIN}:${NPM_ADMIN_PORT}"

# Direct access with extracted ports
echo "=== Direct Access (HTTP with ports) ==="
echo "- OpenEMR: http://localhost:${OPENEMR_PORT}"
echo "- Telehealth: http://localhost:${TELEHEALTH_PORT}"
echo "- WordPress: http://localhost:${WORDPRESS_PORT}"
echo "- Jitsi: http://localhost:${JITSI_PORT}"

echo "Important notes:"
echo "- NPM is configured to handle HTTPS automatically, no need to specify ports"
echo "- To stop containers without removing data, run this script with the --stop option"
echo "- To shut down all containers, run this script with the --reset option"
echo "- To remove all containers, networks, and volumes, run with the --purge option"
echo "=================================================="

# Display network connection information
display_network_info
