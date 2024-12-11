#!/usr/bin/bash

# Color definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print messages in green
print_green() {
    echo -e "${GREEN}$1${NC}"
}

# Function to print messages in red
print_red() {
    echo -e "${RED}$1${NC}"
}

# Function to get primary IP address
get_primary_ip() {
    # Get the primary IP address (excluding localhost)
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127' | head -n 1
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Update and install necessary packages including Redis
print_green "Updating package lists and installing Redis..."
apt update && apt upgrade -y
apt install -y redis-server git python3-pip python3-venv build-essential \
    python3-dev libffi-dev libssl-dev whiptail python3-yaml

# Check if Redis installation was successful
if ! systemctl is-active --quiet redis-server; then
    print_green "Starting Redis server..."
    systemctl enable --now redis-server
    sleep 2
    if ! systemctl is-active --quiet redis-server; then
        echo "Failed to start Redis server. Please check the logs."
        exit 1
    fi
fi

# Set up SearXNG user and directories
print_green "Creating user and directories for SearXNG..."
id -u searxng &>/dev/null || useradd -r -s /bin/false searxng
mkdir -p /usr/local/searxng /etc/searxng
chown searxng:searxng /usr/local/searxng /etc/searxng

# Clone SearXNG repository
print_green "Cloning SearXNG repository..."
if [ -d "/usr/local/searxng/searxng-src" ]; then
    print_green "Directory exists, updating repository..."
    cd /usr/local/searxng/searxng-src
    sudo -u searxng git pull
else
    sudo -u searxng git clone https://github.com/searxng/searxng.git /usr/local/searxng/searxng-src
fi

# Set up Python virtual environment
print_green "Setting up Python environment..."
sudo -u searxng python3 -m venv /usr/local/searxng/searx-pyenv
source /usr/local/searxng/searx-pyenv/bin/activate || exit 1

# Install Python packages with error checking
print_green "Installing Python dependencies..."
pip install --upgrade pip setuptools wheel || exit 1
pip install pyyaml || exit 1  # Install PyYAML explicitly
pip install -e /usr/local/searxng/searxng-src || exit 1

# Prompt for configuration settings with defaults and validation
print_green "Configuring SearXNG settings..."

# Ask if user wants to input own secret key
if (whiptail --title "Secret Key" --yesno "Do you want to enter your own secret key? If not, a random one will be generated." 8 78); then
    SECRET_KEY=$(whiptail --inputbox "Enter your secret key (min. 32 characters):" 8 78 --title "Secret Key" 3>&1 1>&2 2>&3)
    # Validate secret key length
    while [ ${#SECRET_KEY} -lt 32 ]; do
        whiptail --msgbox "Secret key must be at least 32 characters long!" 8 78
        SECRET_KEY=$(whiptail --inputbox "Enter your secret key (min. 32 characters):" 8 78 --title "Secret Key" 3>&1 1>&2 2>&3)
    done
else
    SECRET_KEY=$(openssl rand -hex 32)
    whiptail --msgbox "Generated random secret key: ${SECRET_KEY}" 12 78
fi

# Validation function for port
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    fi
    return 1
}

# Input with validation
BIND_ADDRESS=$(whiptail --inputbox "Enter bind address for SearXNG (default: 0.0.0.0):" 8 78 "0.0.0.0" --title "Bind Address" 3>&1 1>&2 2>&3)
while true; do
    PORT=$(whiptail --inputbox "Enter port for SearXNG (default: 8888):" 8 78 "8888" --title "Port" 3>&1 1>&2 2>&3)
    if validate_port "$PORT"; then
        break
    else
        whiptail --msgbox "Invalid port number. Please enter a number between 1 and 65535." 8 78
    fi
done
REDIS_URL=$(whiptail --inputbox "Enter Redis URL (default: redis://127.0.0.1:6379/0):" 8 78 "redis://127.0.0.1:6379/0" --title "Redis URL" 3>&1 1>&2 2>&3)
DEBUG_MODE=$(whiptail --title "Debug Mode" --yesno "Enable debug mode?" 8 78 3>&1 1>&2 2>&3 && echo "true" || echo "false")

# Write settings to configuration file
print_green "Writing configuration to /etc/searxng/settings.yml..."
cat <<EOL > /etc/searxng/settings.yml
# SearXNG settings
use_default_settings: true
general:
  debug: ${DEBUG_MODE}
  instance_name: "SearXNG"
  privacypolicy_url: false
  contact_url: false
server:
  bind_address: "${BIND_ADDRESS}"
  port: ${PORT}
  secret_key: "${SECRET_KEY}"
  limiter: true
  image_proxy: true
redis:
  url: "${REDIS_URL}"
ui:
  static_use_hash: true
enabled_plugins:
  - 'Hash plugin'
  - 'Self Information'
  - 'Tracker URL remover'
  - 'Ahmia blacklist'
search:
  safe_search: 2
  autocomplete: 'google'
engines:
  - name: google
    engine: google
    shortcut: gg
    use_mobile_ui: false
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
    display_error_messages: true
  - name: wikipedia
    engine: wikipedia
    shortcut: wp
  - name: github
    engine: github
    shortcut: gh
EOL

# Set proper permissions
chown searxng:searxng /etc/searxng/settings.yml
chmod 640 /etc/searxng/settings.yml

# Create systemd service file
print_green "Creating systemd service..."
cat <<EOL > /etc/systemd/system/searxng.service
[Unit]
Description=SearXNG service
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=searxng
Group=searxng
Environment="SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml"
ExecStart=/usr/local/searxng/searx-pyenv/bin/python -m searx.webapp
WorkingDirectory=/usr/local/searxng/searxng-src
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Start and enable the service
systemctl daemon-reload
systemctl enable --now searxng

# Get the actual IP address
CONTAINER_IP=$(get_primary_ip)

# Display a summary of configurations
print_green "Installation complete. Here is a summary of your configurations:"
print_red "Bind Address: ${BIND_ADDRESS}"
print_red "Port: ${PORT}"
print_red "Redis URL: ${REDIS_URL}"
print_red "Debug Mode: ${DEBUG_MODE}"
print_red "Secret Key: ${SECRET_KEY}"
echo "Service Status:"
systemctl status searxng

print_green "You can now access SearXNG at http://${CONTAINER_IP}:${PORT}"

# Optional: Add some basic search engines to the configuration
print_green "Basic search engines have been configured (Google, DuckDuckGo, Wikipedia, GitHub)"
print_green "You can modify the engines in /etc/searxng/settings.yml"

# Final check
if systemctl is-active --quiet searxng; then
    print_green "SearXNG is running successfully!"
else
    echo "Warning: SearXNG service is not running. Please check the logs with: journalctl -u searxng"
fi
