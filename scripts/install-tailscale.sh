#!/bin/bash

# Install Tailscale on Raspberry Pi
# This script detects the ARM architecture and installs the appropriate Tailscale version

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   log_error "This script should not be run as root. Run as pi user with sudo when needed."
   exit 1
fi

# Check if we're on a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo; then
    log_warn "This doesn't appear to be a Raspberry Pi. Proceeding anyway..."
fi

# Detect architecture
ARCH=$(uname -m)
log_info "Detected architecture: $ARCH"

# Update package list
log_info "Updating package list..."
sudo apt update

# Install prerequisites
log_info "Installing prerequisites..."
sudo apt install -y curl gnupg2 software-properties-common apt-transport-https

# Add Tailscale's GPG key
log_info "Adding Tailscale GPG key..."
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

# Add Tailscale repository
log_info "Adding Tailscale repository..."
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list

# Update package list with new repository
log_info "Updating package list with Tailscale repository..."
sudo apt update

# Install Tailscale
log_info "Installing Tailscale..."
sudo apt install -y tailscale

# Enable Tailscale service
log_info "Enabling Tailscale service..."
sudo systemctl enable tailscaled
sudo systemctl start tailscaled

# Check service status
if sudo systemctl is-active --quiet tailscaled; then
    log_info "Tailscale daemon is running successfully"
else
    log_error "Tailscale daemon failed to start"
    exit 1
fi

# Show Tailscale version
TAILSCALE_VERSION=$(tailscale version)
log_info "Installed Tailscale version: $TAILSCALE_VERSION"

echo ""
log_info "Starting Tailscale setup..."

# Connect to Tailscale network
log_info "Connecting to Tailscale network..."
echo ""
echo "You will need to authenticate this device. A URL will be provided below."
echo "Please open the URL in a web browser and authenticate this device."
echo ""

# Start Tailscale with basic configuration
# This will provide the authentication URL
sudo tailscale up

# Wait a moment for connection to establish
sleep 3

# Check if we're connected
if sudo tailscale status | grep -q "^[0-9]"; then
    log_info "Successfully connected to Tailscale!"
    
    # Get Tailscale IP
    TAILSCALE_IP=$(sudo tailscale ip --4 2>/dev/null || echo "Unable to get IP")
    if [ "$TAILSCALE_IP" != "Unable to get IP" ]; then
        log_info "Your Tailscale IP address: $TAILSCALE_IP"
    fi
    
    # Show status
    echo ""
    log_info "Current Tailscale status:"
    sudo tailscale status
    
else
    log_warn "Tailscale connection may still be pending authentication."
    log_info "Please check the authentication URL above and try 'sudo tailscale status' later."
fi

echo ""
log_info "Tailscale installation and setup completed!"
echo ""
echo "Your device is now accessible remotely via Tailscale through WiFi."
echo "This provides secure remote access to this Pi and indirect access to the mesh network."
echo ""
echo "Useful commands:"
echo "  sudo tailscale status    - Show connection status and peer list"
echo "  sudo tailscale ip        - Show your Tailscale IP address"
echo "  sudo tailscale ping <ip> - Test connectivity to another Tailscale device"
echo "  sudo tailscale down      - Disconnect from Tailscale"
echo "  sudo tailscale up        - Reconnect to Tailscale"
echo ""
log_info "You can now access this Pi remotely using the Tailscale IP address"
log_info "SSH example: ssh pi@$TAILSCALE_IP"
log_info "Web interface: http://$TAILSCALE_IP (if nginx is running)" 