#!/bin/bash

# Nightwatch Chat - Access Information Script
# Shows all ways to access from mobile devices

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "========================================"
echo "   🌙 NIGHTWATCH CHAT - ACCESS INFO   "
echo "========================================"
echo

# Get Pi's IP addresses
echo -e "${BLUE}📡 NETWORK INFORMATION:${NC}"
echo "Hostname: $(hostname)"

# Get all IP addresses
IPS=($(hostname -I))
for ip in "${IPS[@]}"; do
    echo "IP Address: $ip"
done

echo

# Local access methods
echo -e "${GREEN}📱 MOBILE ACCESS METHODS:${NC}"
echo

echo -e "${YELLOW}1. Direct IP Access:${NC}"
for ip in "${IPS[@]}"; do
    echo "   http://$ip"
done

echo -e "${YELLOW}2. Hostname Access:${NC}"
echo "   http://$(hostname).local"
echo "   http://raspberrypi.local"

echo

# QR Code generation (if qrencode is available)
if command -v qrencode &> /dev/null; then
    echo -e "${YELLOW}3. QR Code for easy mobile access:${NC}"
    main_ip="${IPS[0]}"
    echo "   Scan this QR code with your phone:"
    qrencode -t ansiutf8 "http://$main_ip"
    echo
fi

# Network scanning
echo -e "${CYAN}🔍 NETWORK TROUBLESHOOTING:${NC}"
echo

echo "If you can't connect from your phone:"
echo "1. Make sure phone and Pi are on same WiFi network"
echo "2. Check if Pi's firewall allows port 80:"
echo "   sudo ufw status"
echo "   sudo ufw allow 80"
echo
echo "3. Test from Pi itself:"
echo "   curl http://localhost"
echo
echo "4. Test from another device:"
for ip in "${IPS[@]}"; do
    echo "   ping $ip"
done

echo
echo -e "${GREEN}📊 SERVICE STATUS:${NC}"
if command -v docker-compose &> /dev/null; then
    docker-compose ps 2>/dev/null || echo "Docker containers not running"
else
    echo "Docker Compose not available"
fi

echo
echo -e "${BLUE}💡 TIPS:${NC}"
echo "• Use IP address if hostname doesn't work"
echo "• Make sure both devices are on same network"
echo "• Try turning WiFi off/on on your phone"
echo "• Clear browser cache if page doesn't load" 