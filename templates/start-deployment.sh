#!/bin/bash
# Deployment Startup Script for All-In-One Telehealth Platform
# This script starts all components and ensures proper network connections

# Set environment variables
PROJECT_NAME=$(basename $(pwd))
ENVIRONMENT=${1:-"staging"}  # Default to staging if not specified
PROXY_NETWORK="proxy-$PROJECT_NAME"
FRONTEND_NETWORK="frontend-$PROJECT_NAME"
SHARED_NETWORK="${PROJECT_NAME}-shared-network"

echo "====================================================="
echo "Starting All-In-One Telehealth Platform Deployment"
echo "Project: $PROJECT_NAME"
echo "Environment: $ENVIRONMENT"
echo "====================================================="

# Step 1: Create required Docker networks
echo "Step 1: Creating Docker networks..."
echo "-----------------------------------"

# Create the proxy network
echo "Creating proxy network ($PROXY_NETWORK)..."
docker network create $PROXY_NETWORK 2>/dev/null || echo "Proxy network already exists"

# Create the frontend network
echo "Creating frontend network ($FRONTEND_NETWORK)..."
docker network create $FRONTEND_NETWORK 2>/dev/null || echo "Frontend network already exists"

# Create the shared network
echo "Creating shared network ($SHARED_NETWORK)..."
docker network create $SHARED_NETWORK 2>/dev/null || echo "Shared network already exists"

# Step 2: Start NPM (Nginx Proxy Manager) first
echo "Step 2: Starting Nginx Proxy Manager..."
echo "--------------------------------------"
cd proxy
docker-compose up -d
cd ..

# Wait for NPM to be ready
echo "Waiting for NPM to be ready..."
sleep 10

# Step 3: Start OpenEMR
echo "Step 3: Starting OpenEMR..."
echo "--------------------------"
cd openemr
docker-compose up -d
cd ..

# Step 4: Start Telehealth
echo "Step 4: Starting Telehealth..."
echo "----------------------------"
cd telehealth
docker-compose up -d
cd ..

# Step 5: Start Jitsi (if it exists)
if [ -d "jitsi-docker" ]; then
    echo "Step 5: Starting Jitsi..."
    echo "------------------------"
    cd jitsi-docker
    docker-compose up -d
    cd ..
fi

# Step 6: Start WordPress (if it exists)
if [ -d "wordpress" ]; then
    echo "Step 6: Starting WordPress..."
    echo "----------------------------"
    cd wordpress
    docker-compose up -d
    cd ..
fi

# Step 7: Connect containers to networks
echo "Step 7: Connecting containers to networks..."
echo "------------------------------------------"

# Get container names
NPM_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-proxy-proxy-1" | head -n 1)
OPENEMR_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-openemr-openemr-1" | head -n 1)
TELEHEALTH_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-telehealth-app-1" | head -n 1)
WORDPRESS_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-wordpress-wordpress-1" | head -n 1)
JITSI_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "${PROJECT_NAME}-jitsi-web-1" | head -n 1)

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

# Step 8: Display access information
echo "Step 8: Setup Complete"
echo "-------------------"
echo "The All-In-One Telehealth Platform deployment is complete!"
echo ""
echo "Access Information:"
echo "- OpenEMR: http://localhost:$(grep HTTP_PORT openemr/.env | cut -d= -f2)"
echo "- Nginx Proxy Manager Admin: http://localhost:$(grep ADMIN_PORT proxy/.env | cut -d= -f2 || echo "81")"
echo "- WordPress: http://localhost:$(grep HTTP_PORT wordpress/.env | cut -d= -f2 || echo "33080")"
echo ""
echo "Important notes:"
echo "- Configure proxy hosts in Nginx Proxy Manager to access services via domains"
echo "- Default OpenEMR login: admin / AdminOps2023**"
echo ""
echo "Thank you for using the All-In-One Telehealth Platform!"

# End of script
