#!/bin/bash

# Nightwatch Chat - Pi Zero 2 W Deployment Script
# Optimized for 100 concurrent users

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on Pi
check_pi() {
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        warning "This script is optimized for Raspberry Pi. Continue anyway? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should NOT be run as root. Run as regular user with sudo access."
        exit 1
    fi
}

# System optimization
optimize_system() {
    log "Applying Pi Zero 2 W system optimizations..."
    
    # Enable swap
    log "Configuring swap (512MB)..."
    sudo dphys-swapfile swapoff 2>/dev/null || true
    sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
    sudo dphys-swapfile setup
    sudo dphys-swapfile swapon
    success "Swap configured"
    
    # Optimize kernel parameters
    log "Optimizing network parameters..."
    if ! grep -q "net.core.somaxconn" /etc/sysctl.conf; then
        echo 'net.core.somaxconn = 1024' | sudo tee -a /etc/sysctl.conf
        echo 'net.ipv4.tcp_max_syn_backlog = 1024' | sudo tee -a /etc/sysctl.conf
        echo 'net.core.netdev_max_backlog = 1000' | sudo tee -a /etc/sysctl.conf
        echo 'vm.swappiness = 10' | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
        success "Network parameters optimized"
    else
        log "Network parameters already optimized"
    fi
    
    # GPU memory split optimization
    log "Optimizing GPU memory split..."
    if ! grep -q "gpu_mem=16" /boot/config.txt; then
        echo 'gpu_mem=16' | sudo tee -a /boot/config.txt
        warning "GPU memory optimized. Reboot required after deployment."
    fi
}

# Disable unnecessary services
disable_services() {
    log "Disabling unnecessary services..."
    
    services=("bluetooth" "triggerhappy" "avahi-daemon" "ModemManager")
    
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            sudo systemctl disable "$service" 2>/dev/null || true
            sudo systemctl stop "$service" 2>/dev/null || true
            log "Disabled $service"
        fi
    done
    
    success "Unnecessary services disabled"
}

# Configure Docker for Pi Zero 2 W
optimize_docker() {
    log "Optimizing Docker configuration..."
    
    # Create optimized Docker daemon config
    sudo cat > /tmp/docker-daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1m",
    "max-file": "1"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "default-runtime": "runc"
}
EOF
    
    sudo mv /tmp/docker-daemon.json /etc/docker/daemon.json
    sudo systemctl restart docker
    
    # Wait for Docker to start
    sleep 5
    
    success "Docker optimized for Pi Zero 2 W"
}

# Deploy Nightwatch Chat
deploy_nightwatch() {
    log "Deploying Nightwatch Chat..."
    
    # Check if we're in the right directory
    if [[ ! -f "docker-compose.yml" ]]; then
        error "docker-compose.yml not found. Please run this script from the Mesh-Nightwatch directory."
        exit 1
    fi
    
    # Clean up any existing containers
    log "Cleaning up existing containers..."
    docker-compose down --volumes 2>/dev/null || true
    docker system prune -af --volumes
    
    # Make scripts executable
    chmod +x scripts/*.sh 2>/dev/null || true
    
    # Build optimized containers
    log "Building optimized containers for ARM architecture..."
    docker-compose build --no-cache
    
    # Start the stack
    log "Starting Nightwatch Chat..."
    docker-compose up -d
    
    # Wait for services to start
    sleep 10
    
    success "Nightwatch Chat deployed successfully!"
}

# Verify deployment
verify_deployment() {
    log "Verifying deployment..."
    
    # Check container status
    if docker-compose ps | grep -q "Up"; then
        success "Containers are running"
        docker-compose ps
    else
        error "Some containers failed to start"
        docker-compose logs
        return 1
    fi
    
    # Check memory usage
    total_mem=$(free -m | awk 'NR==2{printf "%.0f", $3}')
    log "Current memory usage: ${total_mem}MB"
    
    if [[ $total_mem -gt 400 ]]; then
        warning "High memory usage detected. Monitor performance closely."
    fi
    
    # Get Pi's IP address
    pi_ip=$(hostname -I | awk '{print $1}')
    
    success "Deployment verification complete!"
    echo
    echo "=== ACCESS YOUR NIGHTWATCH CHAT ==="
    echo "Local:     http://localhost"
    echo "Network:   http://$pi_ip"
    echo "Mobile:    http://$pi_ip"
    echo
    echo "=== MONITORING ==="
    echo "Run: ./scripts/monitor.sh"
    echo "Real-time: watch docker stats"
    echo
}

# Performance tuning advice
show_performance_tips() {
    echo "=== PI ZERO 2 W PERFORMANCE TIPS ==="
    echo
    echo "1. Monitor regularly:"
    echo "   ./scripts/monitor.sh"
    echo
    echo "2. Expected capacity:"
    echo "   - 25 users: Smooth operation"
    echo "   - 50 users: Good performance"
    echo "   - 75 users: Manageable load"
    echo "   - 100 users: At capacity"
    echo
    echo "3. If experiencing issues:"
    echo "   docker-compose restart"
    echo "   ./scripts/monitor.sh"
    echo
    echo "4. Emergency cleanup:"
    echo "   docker system prune -af"
    echo
}

# Main deployment flow
main() {
    echo "========================================"
    echo "  NIGHTWATCH CHAT - PI ZERO 2 W SETUP  "
    echo "========================================"
    echo
    
    check_root
    check_pi
    
    echo "This script will:"
    echo "- Optimize system for 100 concurrent users"
    echo "- Configure Docker for Pi Zero 2 W"
    echo "- Deploy optimized Nightwatch Chat"
    echo "- Disable unnecessary services"
    echo
    echo "Continue with deployment? (y/N)"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Deployment cancelled by user"
        exit 0
    fi
    
    echo
    log "Starting Pi Zero 2 W optimization..."
    
    optimize_system
    disable_services
    optimize_docker
    deploy_nightwatch
    verify_deployment
    show_performance_tips
    
    echo
    success "Pi Zero 2 W deployment complete!"
    warning "Reboot recommended for all optimizations to take effect:"
    echo "  sudo reboot"
}

# Run main function
main "$@" 