#!/bin/bash
# Deployment Startup Script for All-In-One Telehealth Platform
# This script starts all components and ensures proper network connections

# Environment-specific variables (will be replaced during deployment)
DOMAIN_BASE="__DOMAIN_BASE__"
PROJECT_NAME="__PROJECT_NAME__"
ENVIRONMENT="__ENVIRONMENT__"
NPM_ADMIN_PORT="__NPM_ADMIN_PORT__"
NPM_HTTP_PORT="__NPM_HTTP_PORT__"
NPM_HTTPS_PORT="__NPM_HTTPS_PORT__"

# Set network names
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

# Step 8: Configure Nginx Proxy Manager
echo "Step 8: Configuring Nginx Proxy Manager..."
echo "-----------------------------------"

# NPM API credentials
NPM_EMAIL="admin@example.com"
NPM_PASSWORD="changeme"
NPM_URL="http://localhost:${NPM_ADMIN_PORT}"

# Wait for NPM to be fully started
echo "Waiting for NPM API to be available..."
sleep 10

# Function to authenticate with NPM API
get_npm_token() {
    echo "Authenticating with NPM API..."
    
    # Try to log in and get token
    TOKEN_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
        -H "Content-Type: application/json" \
        -d '{"identity":"'"${NPM_EMAIL}"'","secret":"'"${NPM_PASSWORD}"'"}' \
        --retry 5 --retry-delay 2)
    
    # Extract token from response
    TOKEN=$(echo $TOKEN_RESPONSE | grep -o '"token":"[^"]*"' | cut -d\" -f4)
    
    if [ -z "$TOKEN" ]; then
        echo "Failed to authenticate with NPM API. Using default credentials..."
        # Try with default credentials
        DEFAULT_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
            -H "Content-Type: application/json" \
            -d '{"identity":"admin@example.com","secret":"changeme"}' \
            --retry 5 --retry-delay 2)
        
        TOKEN=$(echo $DEFAULT_RESPONSE | grep -o '"token":"[^"]*"' | cut -d\" -f4)
    fi
    
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
    
    # Check if proxy host already exists
    EXISTING=$(curl -s -X GET "${NPM_URL}/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer $TOKEN")
    
    DOMAIN_EXISTS=$(echo $EXISTING | grep -o "\"domain_names\":\[\"$DOMAIN\"\]")
    
    if [ ! -z "$DOMAIN_EXISTS" ]; then
        echo "Proxy host for $DOMAIN already exists. Skipping."
        return 0
    fi
    
    # Create proxy host
    RESPONSE=$(curl -s -X POST "${NPM_URL}/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "domain_names": ["'"$DOMAIN"'"],
            "forward_host": "'"$FORWARD_HOST"'",
            "forward_port": '$FORWARD_PORT',
            "access_list_id": "0",
            "certificate_id": 1,
            "ssl_forced": true,
            "http2_support": true,
            "meta": {
                "letsencrypt_agree": false,
                "dns_challenge": false
            },
            "advanced_config": "",
            "block_exploits": true,
            "caching_enabled": false,
            "allow_websocket_upgrade": '"$WEBSOCKET"',
            "http2_push_preload": false,
            "hsts_enabled": false,
            "hsts_subdomains": false
        }')
    
    if echo $RESPONSE | grep -q "id"; then
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
    
    # Set domain names based on environment and domain base
    if [ "$ENVIRONMENT" = "production" ]; then
        OPENEMR_DOMAIN="$PROJECT_NAME.$DOMAIN_BASE"
        TELEHEALTH_DOMAIN="vc.$PROJECT_NAME.$DOMAIN_BASE"
        JITSI_DOMAIN="vcbknd.$PROJECT_NAME.$DOMAIN_BASE"
        WORDPRESS_DOMAIN="$PROJECT_NAME.$DOMAIN_BASE"
    else
        OPENEMR_DOMAIN="$ENVIRONMENT-$PROJECT_NAME.$DOMAIN_BASE"
        TELEHEALTH_DOMAIN="vc-$ENVIRONMENT.$DOMAIN_BASE"
        JITSI_DOMAIN="vcbknd-$ENVIRONMENT.$DOMAIN_BASE"
        WORDPRESS_DOMAIN="$ENVIRONMENT-$PROJECT_NAME.$DOMAIN_BASE"
    fi
    
    # Create proxy hosts for each service
    if [ ! -z "$OPENEMR_CONTAINER" ]; then
        create_proxy_host "$NPM_TOKEN" "$OPENEMR_DOMAIN" "$OPENEMR_CONTAINER" 80 false
    fi
    
    if [ ! -z "$TELEHEALTH_CONTAINER" ]; then
        create_proxy_host "$NPM_TOKEN" "$TELEHEALTH_DOMAIN" "$TELEHEALTH_CONTAINER" 80 false
    fi
    
    if [ ! -z "$JITSI_CONTAINER" ]; then
        create_proxy_host "$NPM_TOKEN" "$JITSI_DOMAIN" "$JITSI_CONTAINER" 80 true
    fi
    
    if [ ! -z "$WORDPRESS_CONTAINER" ]; then
        create_proxy_host "$NPM_TOKEN" "$WORDPRESS_DOMAIN" "$WORDPRESS_CONTAINER" 80 false
    fi
    
    echo "NPM proxy hosts configuration complete!"
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
