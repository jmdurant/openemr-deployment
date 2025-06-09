#!/bin/bash
set -e

# Update package index
echo "Updating package index..."
sudo apt-get update

# Install required packages
echo "Installing required packages..."
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key
echo "Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Set up the Docker repository
echo "Setting up Docker repository..."
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again
echo "Updating package index with Docker repository..."
sudo apt-get update

# Install Docker Engine
echo "Installing Docker Engine..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add current user to docker group
echo "Adding current user to docker group..."
sudo usermod -aG docker $USER

# Install Docker Compose if not already installed
if ! command -v docker compose &> /dev/null; then
    echo "Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
fi

echo "Docker installation completed successfully!"
echo "You may need to log out and log back in for docker group membership to take effect."

# Start Docker service
echo "Starting Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

# Verify installation
echo "Verifying Docker installation..."
docker --version
docker compose version

echo "Docker setup completed!"
