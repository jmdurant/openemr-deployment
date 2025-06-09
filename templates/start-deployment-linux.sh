#!/bin/bash
# Linux Deployment Startup Script for All-In-One Telehealth Platform
# This script starts all components and ensures proper network connections
# Optimized for remote Linux deployment with vr2fit.com domain

# Set strict error handling
set -e

# Default values
DEFAULT_PROJECT_NAME="{{PROJECT_NAME}}"
DEFAULT_ENVIRONMENT="{{ENVIRONMENT}}"
DEFAULT_DOMAIN_BASE="{{DOMAIN_BASE}}"
DEFAULT_NPM_ADMIN_PORT="{{NPM_ADMIN_PORT}}"
DEFAULT_NPM_HTTP_PORT="{{NPM_HTTP_PORT}}"
DEFAULT_NPM_HTTPS_PORT="{{NPM_HTTPS_PORT}}"

# Use defaults unless overridden
PROJECT_NAME="${OVERRIDE_PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"
ENVIRONMENT="${OVERRIDE_ENVIRONMENT:-$DEFAULT_ENVIRONMENT}"
DOMAIN_BASE="${OVERRIDE_DOMAIN_BASE:-$DEFAULT_DOMAIN_BASE}"
NPM_ADMIN_PORT="${OVERRIDE_NPM_ADMIN_PORT:-$DEFAULT_NPM_ADMIN_PORT}"
NPM_HTTP_PORT="${OVERRIDE_NPM_HTTP_PORT:-$DEFAULT_NPM_HTTP_PORT}"
NPM_HTTPS_PORT="${OVERRIDE_NPM_HTTPS_PORT:-$DEFAULT_NPM_HTTPS_PORT}"

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
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --reset)
            RESET=true
            shift
            ;;
        --project)
            OVERRIDE_PROJECT_NAME="$2"
            shift 2
            ;;
        --environment)
            OVERRIDE_ENVIRONMENT="$2"
            shift 2
            ;;
        --domain)
            OVERRIDE_DOMAIN_BASE="$2"
            shift 2
            ;;
        --npm-admin-port)
            OVERRIDE_NPM_ADMIN_PORT="$2"
            shift 2
            ;;
        --npm-http-port)
            OVERRIDE_NPM_HTTP_PORT="$2"
            shift 2
            ;;
        --npm-https-port)
            OVERRIDE_NPM_HTTPS_PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--reset] [--project PROJECT_NAME] [--environment ENVIRONMENT] [--domain DOMAIN_BASE]"
            exit 1
            ;;
    esac
done

# If reset flag is provided, reset the deployment
if [ "$RESET" = true ]; then
    reset_deployment "$PROJECT_NAME" "$ENVIRONMENT"
fi

# Display deployment information
echo "===================================================="
echo "STARTING DEPLOYMENT"
echo "Project: $PROJECT_NAME"
echo "Environment: $ENVIRONMENT"
echo "Domain: $DOMAIN_BASE"
echo "NPM Admin Port: $NPM_ADMIN_PORT"
echo "NPM HTTP Port: $NPM_HTTP_PORT"
echo "NPM HTTPS Port: $NPM_HTTPS_PORT"
echo "===================================================="

# Define network names
SHARED_NETWORK_NAME="${PROJECT_NAME}-shared-network"
ENV_FRONTEND_NETWORK="frontend-${ENVIRONMENT}"
ENV_PROXY_NETWORK="proxy-${ENVIRONMENT}"

# Function to run docker-compose
run_docker_compose() {
    local component=$1
    local component_name=$2
    
    echo "Starting $component_name..."
    
    # Check if the directory exists
    if [ ! -d "$component" ]; then
        echo "ERROR: $component directory not found!"
        return 1
    fi
    
    # Change to the component directory
    cd "$component"
    
    # Check if docker-compose file exists
    if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
        echo "ERROR: No docker-compose.yml or docker-compose.yaml file found in $component directory!"
        cd ..
        return 1
    fi
    
    # Run docker-compose up
    echo "Running docker-compose up in $component directory..."
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    # Check result
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to start $component_name containers!"
        cd ..
        return 1
    fi
    
    echo "$component_name containers started successfully."
    cd ..
    return 0
}

# Create shared network
echo "Creating shared network ($SHARED_NETWORK_NAME)..."
docker network create "$SHARED_NETWORK_NAME" 2>/dev/null || echo "Shared network already exists"

# Create the environment-specific frontend network
echo "Creating environment-specific frontend network ($ENV_FRONTEND_NETWORK)..."
docker network create "$ENV_FRONTEND_NETWORK" 2>/dev/null || echo "Environment-specific frontend network already exists"

# Step 1: Start NPM (Nginx Proxy Manager) first
echo "Step 1: Starting Nginx Proxy Manager..."
echo "--------------------------------------"
run_docker_compose "proxy" "Nginx Proxy Manager"

# Wait for NPM to be ready
echo "Waiting for NPM to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
NPM_READY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s "http://localhost:$NPM_ADMIN_PORT" > /dev/null; then
        NPM_READY=true
        break
    fi
    echo "NPM not ready yet, waiting... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
    RETRY_COUNT=$((RETRY_COUNT+1))
    sleep 10
done

if [ "$NPM_READY" = false ]; then
    echo "ERROR: NPM did not become ready within the expected time!"
    echo "Please check the NPM container logs for issues."
    exit 1
fi

echo "NPM is ready!"

# Step 2: Start Jitsi
echo "Step 2: Starting Jitsi..."
echo "-----------------------"
run_docker_compose "jitsi-docker" "Jitsi"

# Step 3: Start Telehealth
echo "Step 3: Starting Telehealth..."
echo "----------------------------"
run_docker_compose "telehealth" "Telehealth"

# Step 4: Start OpenEMR
echo "Step 4: Starting OpenEMR..."
echo "--------------------------"
run_docker_compose "openemr" "OpenEMR"

# Step 5: Start WordPress
echo "Step 5: Starting WordPress..."
echo "---------------------------"
if [ -d "wordpress" ]; then
    run_docker_compose "wordpress" "WordPress"
else
    echo "WordPress directory not found, skipping..."
fi

# Function to get NPM token
get_npm_token() {
    local email="admin@example.com"
    local password="changeme"
    local npm_url="http://localhost:$NPM_ADMIN_PORT"
    
    # Try to get token
    local token=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"$email\",\"secret\":\"$password\"}" \
        "$npm_url/api/tokens" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    # If token is empty, try with default credentials
    if [ -z "$token" ]; then
        echo "Failed to get token with provided credentials, trying default credentials..."
        token=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d '{"identity":"admin@example.com","secret":"changeme"}' \
            "$npm_url/api/tokens" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    fi
    
    echo "$token"
}

# Connect containers to networks if needed
echo "Ensuring all containers are connected to the correct networks..."

# Get container IDs
TELEHEALTH_APP_CONTAINER=$(docker ps --filter "name=${PROJECT_NAME}-telehealth-app" --format "{{.ID}}")
OPENEMR_CONTAINER=$(docker ps --filter "name=${PROJECT_NAME}-openemr-openemr" --format "{{.ID}}")
JITSI_WEB_CONTAINER=$(docker ps --filter "name=${PROJECT_NAME}-jitsi-docker-web" --format "{{.ID}}")
NPM_CONTAINER=$(docker ps --filter "name=${PROJECT_NAME}-proxy-app" --format "{{.ID}}")

# Connect containers to networks
if [ ! -z "$TELEHEALTH_APP_CONTAINER" ]; then
    echo "Connecting Telehealth App to networks..."
    docker network connect "$ENV_FRONTEND_NETWORK" "$TELEHEALTH_APP_CONTAINER" 2>/dev/null || echo "Already connected"
    docker network connect "$SHARED_NETWORK_NAME" "$TELEHEALTH_APP_CONTAINER" 2>/dev/null || echo "Already connected"
fi

if [ ! -z "$OPENEMR_CONTAINER" ]; then
    echo "Connecting OpenEMR to networks..."
    docker network connect "$ENV_FRONTEND_NETWORK" "$OPENEMR_CONTAINER" 2>/dev/null || echo "Already connected"
    docker network connect "$SHARED_NETWORK_NAME" "$OPENEMR_CONTAINER" 2>/dev/null || echo "Already connected"
fi

if [ ! -z "$JITSI_WEB_CONTAINER" ]; then
    echo "Connecting Jitsi Web to networks..."
    docker network connect "$ENV_FRONTEND_NETWORK" "$JITSI_WEB_CONTAINER" 2>/dev/null || echo "Already connected"
    docker network connect "$SHARED_NETWORK_NAME" "$JITSI_WEB_CONTAINER" 2>/dev/null || echo "Already connected"
fi

if [ ! -z "$NPM_CONTAINER" ]; then
    echo "Connecting NPM to networks..."
    docker network connect "$ENV_FRONTEND_NETWORK" "$NPM_CONTAINER" 2>/dev/null || echo "Already connected"
    docker network connect "$SHARED_NETWORK_NAME" "$NPM_CONTAINER" 2>/dev/null || echo "Already connected"
fi

echo "All containers connected to networks."

echo "===================================================="
echo "DEPLOYMENT COMPLETE"
echo "===================================================="
echo "Your All-In-One Telehealth Platform is now running!"
echo ""
echo "Access your services at:"
echo "- Nginx Proxy Manager: http://localhost:$NPM_ADMIN_PORT"
echo "- OpenEMR: https://openemr.$DOMAIN_BASE"
echo "- Telehealth: https://vc.$DOMAIN_BASE"
echo "- Jitsi: https://vcbknd.$DOMAIN_BASE"
echo "- WordPress: https://$DOMAIN_BASE"
echo ""
echo "NOTE: It may take a few minutes for all services to fully initialize."
echo "If you encounter any issues, check the container logs with 'docker logs <container_name>'."
echo "===================================================="
