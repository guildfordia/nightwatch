#!/bin/bash

# Nightwatch Chat Resource Monitor
# For Pi Zero 2 W with 100 users

echo "=== NIGHTWATCH RESOURCE MONITOR ==="
echo "$(date)"
echo "======================================"

# System resources
echo "MEMORY USAGE:"
free -h | grep -E "Mem:|Swap:"

echo -e "\nCPU USAGE:"
top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print "CPU Usage: " 100 - $1 "%"}'

echo -e "\nDISK USAGE:"
df -h / | tail -1 | awk '{print "Root: " $3 "/" $2 " (" $5 " used)"}'

echo -e "\nCONTAINER STATS:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"

echo -e "\nCONNECTION COUNT:"
CONNECTIONS=$(docker exec irc-bridge netstat -an | grep :3000 | grep ESTABLISHED | wc -l)
echo "WebSocket connections: $CONNECTIONS"

IRC_CONNECTIONS=$(docker exec ngircd netstat -an | grep :6667 | grep ESTABLISHED | wc -l)
echo "IRC connections: $IRC_CONNECTIONS"

echo -e "\nNGIRCD CHANNEL INFO:"
echo "INFO nightwatch" | nc localhost 6667 | grep -E "users|#nightwatch" || echo "Channel info not available"

echo -e "\nLOAD AVERAGE:"
uptime

echo "======================================" 