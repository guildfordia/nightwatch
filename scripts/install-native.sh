#!/bin/bash

# Nightwatch Chat - Native Installation (No Docker)
# Optimized for Pi Zero 2 W - Direct system installation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should NOT be run as root. Run as regular user with sudo access."
        exit 1
    fi
}

# Install system dependencies
install_dependencies() {
    log "Installing system dependencies..."
    
    sudo apt update
    sudo apt install -y \
        ngircd \
        nginx \
        golang-go \
        git \
        curl \
        htop \
        qrencode
    
    success "Dependencies installed"
}

# Configure ngircd
configure_ngircd() {
    log "Configuring ngircd IRC server..."
    
    # Backup original config
    sudo cp /etc/ngircd/ngircd.conf /etc/ngircd/ngircd.conf.backup 2>/dev/null || true
    
    # Create optimized ngircd config
    sudo tee /etc/ngircd/ngircd.conf > /dev/null << 'EOF'
[Global]
Name = nightwatch.irc
AdminInfo1 = Nightwatch IRC Server
AdminInfo2 = Pi Zero 2W Local Network
AdminEMail = admin@nightwatch.local
Listen = 0.0.0.0
MotdPhrase = Nightwatch Chat - Native Installation
ServerUID = ngircd
ServerGID = ngircd
MaxConnections = 150
MaxConnectionsIP = 25
MaxJoins = 3
MaxNickLength = 12
PingTimeout = 300
PongTimeout = 60
IdleTimeout = 900

[Options]
RequireAuthPing = no
PAM = no
Bind = 0.0.0.0
Port = 6667
MaxChannels = 1
MaxListSize = 100

[Limits]
MaxNickLength = 12
MaxChannelNameLength = 15
MaxTopicLength = 80
MaxAwayLen = 40

[Channel]
name = #nightwatch
topic = Nightwatch Chat [Native - Max 100 users]
modes = +nt
maxusers = 100
EOF

    # Enable and start ngircd
    sudo systemctl enable ngircd
    sudo systemctl restart ngircd
    
    success "ngircd configured and started"
}

# Build Go IRC bridge
build_irc_bridge() {
    log "Building IRC bridge..."
    
    # Create bridge directory
    sudo mkdir -p /opt/nightwatch
    sudo chown $USER:$USER /opt/nightwatch
    
    # Copy Go bridge source
    cp -r irc-bridge-go/* /opt/nightwatch/
    
    # Build the bridge
    cd /opt/nightwatch
    go mod tidy
    go build -o nightwatch-bridge main.go
    
    success "IRC bridge built"
}

# Create systemd service for IRC bridge
create_bridge_service() {
    log "Creating IRC bridge service..."
    
    sudo tee /etc/systemd/system/nightwatch-bridge.service > /dev/null << EOF
[Unit]
Description=Nightwatch IRC Bridge
After=network.target ngircd.service
Requires=ngircd.service

[Service]
Type=simple
User=$USER
WorkingDirectory=/opt/nightwatch
ExecStart=/opt/nightwatch/nightwatch-bridge
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable nightwatch-bridge
    sudo systemctl start nightwatch-bridge
    
    success "IRC bridge service created and started"
}

# Configure nginx
configure_nginx() {
    log "Configuring nginx..."
    
    # Backup default config
    sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.backup 2>/dev/null || true
    
    # Create Nightwatch nginx config
    sudo tee /etc/nginx/sites-available/nightwatch > /dev/null << 'EOF'
upstream irc_backend {
    server 127.0.0.1:3000;
    keepalive 32;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Performance optimizations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 100;
    client_max_body_size 1k;
    client_body_timeout 10;
    client_header_timeout 10;
    send_timeout 10;
    
    # Root directory for static files
    root /opt/nightwatch/html;
    index index.html;
    
    # Serve the IRC client
    location / {
        try_files $uri $uri/ =404;
        
        # Cache static files
        expires 1h;
        add_header Cache-Control "public, immutable";
    }
    
    # Proxy WebSocket connections to IRC bridge
    location /ws {
        proxy_pass http://irc_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket timeouts
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 5s;
        
        # Disable buffering for WebSocket
        proxy_buffering off;
    }
}
EOF

    # Remove default site and enable nightwatch
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo ln -sf /etc/nginx/sites-available/nightwatch /etc/nginx/sites-enabled/
    
    # Copy HTML files
    sudo mkdir -p /opt/nightwatch/html
    sudo cp -r html/* /opt/nightwatch/html/
    sudo chown -R www-data:www-data /opt/nightwatch/html
    
    # Test and restart nginx
    sudo nginx -t
    sudo systemctl restart nginx
    
    success "nginx configured and restarted"
}

# System optimizations for Pi Zero 2 W
optimize_system() {
    log "Applying system optimizations..."
    
    # Swap optimization
    if ! grep -q "CONF_SWAPSIZE=512" /etc/dphys-swapfile; then
        sudo dphys-swapfile swapoff
        sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
        sudo dphys-swapfile setup
        sudo dphys-swapfile swapon
        log "Swap configured to 512MB"
    fi
    
    # Network optimizations
    if ! grep -q "net.core.somaxconn" /etc/sysctl.conf; then
        echo 'net.core.somaxconn = 1024' | sudo tee -a /etc/sysctl.conf
        echo 'net.ipv4.tcp_max_syn_backlog = 1024' | sudo tee -a /etc/sysctl.conf
        echo 'net.core.netdev_max_backlog = 1000' | sudo tee -a /etc/sysctl.conf
        echo 'vm.swappiness = 10' | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
        log "Network parameters optimized"
    fi
    
    # GPU memory optimization for headless
    if ! grep -q "gpu_mem=16" /boot/config.txt; then
        echo 'gpu_mem=16' | sudo tee -a /boot/config.txt
        warning "GPU memory optimized. Reboot required for this change."
    fi
    
    success "System optimizations applied"
}

# Create native monitoring script
create_native_monitor() {
    log "Creating native monitoring script..."
    
    tee /opt/nightwatch/monitor-native.sh > /dev/null << 'EOF'
#!/bin/bash

# Native Nightwatch Monitor (No Docker)

echo "=== NIGHTWATCH NATIVE MONITOR ==="
echo "$(date)"
echo "=================================="

echo "MEMORY USAGE:"
free -h | grep -E "Mem:|Swap:"

echo -e "\nCPU USAGE:"
top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print "CPU Usage: " 100 - $1 "%"}'

echo -e "\nDISK USAGE:"
df -h / | tail -1 | awk '{print "Root: " $3 "/" $2 " (" $5 " used)"}'

echo -e "\nSERVICE STATUS:"
echo "ngircd: $(systemctl is-active ngircd)"
echo "nightwatch-bridge: $(systemctl is-active nightwatch-bridge)"
echo "nginx: $(systemctl is-active nginx)"

echo -e "\nCONNECTIONS:"
bridge_connections=$(ss -tuln | grep :3000 | wc -l)
irc_connections=$(ss -tuln | grep :6667 | wc -l)
http_connections=$(ss -tuln | grep :80 | wc -l)
echo "IRC Bridge: $bridge_connections"
echo "IRC Server: $irc_connections"
echo "HTTP Server: $http_connections"

echo -e "\nPROCESS INFO:"
echo "IRC Server PID: $(pgrep ngircd || echo 'Not running')"
echo "Bridge PID: $(pgrep nightwatch-bridge || echo 'Not running')"
echo "Nginx PID: $(pgrep nginx | head -1 || echo 'Not running')"

echo -e "\nLOAD AVERAGE:"
uptime

echo "=================================="
EOF

    chmod +x /opt/nightwatch/monitor-native.sh
    
    success "Native monitoring script created"
}

# Verify installation
verify_installation() {
    log "Verifying installation..."
    
    # Check services
    services=("ngircd" "nightwatch-bridge" "nginx")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            success "$service is running"
        else
            error "$service is not running"
            sudo systemctl status "$service"
        fi
    done
    
    # Test local connection
    if curl -s http://localhost > /dev/null; then
        success "Web interface is accessible"
    else
        error "Web interface is not accessible"
    fi
    
    # Get network info
    pi_ip=$(hostname -I | awk '{print $1}')
    
    echo
    echo "=== NIGHTWATCH NATIVE INSTALLATION COMPLETE ==="
    echo
    echo "🌐 Access URLs:"
    echo "   Local:   http://localhost"
    echo "   Network: http://$pi_ip"
    echo
    echo "📊 Monitoring:"
    echo "   /opt/nightwatch/monitor-native.sh"
    echo
    echo "🔧 Service Management:"
    echo "   sudo systemctl status ngircd"
    echo "   sudo systemctl status nightwatch-bridge"
    echo "   sudo systemctl status nginx"
    echo
    echo "📁 Installation Directory:"
    echo "   /opt/nightwatch/"
    echo
    echo "💾 Memory Benefits vs Docker:"
    echo "   ~50-100MB less RAM usage"
    echo "   Faster startup times"
    echo "   Direct system integration"
    echo
}

# Main installation
main() {
    echo "========================================="
    echo "  NIGHTWATCH NATIVE INSTALLATION       "
    echo "  (No Docker - Direct System Install)  "
    echo "========================================="
    echo
    
    check_root
    
    if [[ ! -f "docker-compose.yml" ]]; then
        error "Please run this script from the Mesh-Nightwatch directory"
        exit 1
    fi
    
    echo "This will install Nightwatch Chat natively on your system:"
    echo "- ngircd IRC server"
    echo "- Go IRC bridge"  
    echo "- nginx web server"
    echo "- System optimizations"
    echo
    echo "Continue? (y/N)"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Installation cancelled"
        exit 0
    fi
    
    install_dependencies
    optimize_system
    configure_ngircd
    build_irc_bridge
    create_bridge_service
    configure_nginx
    create_native_monitor
    verify_installation
    
    success "Native installation complete!"
    warning "Reboot recommended for all optimizations to take effect"
}

main "$@" 