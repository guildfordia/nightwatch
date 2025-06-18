#!/bin/bash

# Nightwatch Chat - Quick Update Script
# For updating code without re-optimizing the system

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

main() {
    echo "===================================="
    echo "   NIGHTWATCH CHAT - QUICK UPDATE   "
    echo "===================================="
    echo
    
    # Check if in right directory
    if [[ ! -f "docker-compose.yml" ]]; then
        echo "Error: Run this script from the Mesh-Nightwatch directory"
        exit 1
    fi
    
    log "Stopping current containers..."
    docker-compose down
    
    log "Rebuilding updated containers..."
    docker-compose build --no-cache
    
    log "Starting updated services..."
    docker-compose up -d
    
    # Wait for startup
    sleep 5
    
    log "Checking status..."
    docker-compose ps
    
    success "Update complete!"
    
    # Show access info
    pi_ip=$(hostname -I | awk '{print $1}')
    echo
    echo "Access: http://$pi_ip"
    echo "Monitor: ./scripts/monitor.sh"
}

main "$@" 