#!/bin/bash
# Script to download and install a default WordPress theme
# This will be run inside the WordPress container

# Define themes to download - using URLs that always point to the latest versions
THEMES=(
  "https://downloads.wordpress.org/theme/twentytwentyfour.zip"
  "https://downloads.wordpress.org/theme/astra.zip"
  "https://downloads.wordpress.org/theme/kadence.zip"
)

# Create themes directory if it doesn't exist
mkdir -p /var/www/html/wp-content/themes/custom-themes

# Download and install themes
for theme_url in "${THEMES[@]}"; do
  echo "Downloading theme from: $theme_url"
  theme_file=$(basename "$theme_url")
  theme_name="${theme_file%.zip}"
  
  # Download the theme
  wget -q "$theme_url" -O "/tmp/$theme_file"
  
  # Unzip the theme to the themes directory
  unzip -q -o "/tmp/$theme_file" -d /var/www/html/wp-content/themes/
  
  # Clean up the zip file
  rm "/tmp/$theme_file"
  
  echo "Theme $theme_name installed successfully"
done

# Set permissions
chown -R www-data:www-data /var/www/html/wp-content/themes/

echo "All themes installed successfully"
