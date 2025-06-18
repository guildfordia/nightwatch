#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display node status
display_node_status() {
    local status=$1
    if [ "$status" = "up" ]; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
}

# Function to display metrics
display_metrics() {
    local metrics=$1
    echo "┌──────────────────────────────────────────────┐"
    echo "│              Mesh Network Status              │"
    echo "├──────────────────────────────────────────────┤"
    
    # Parse and display each node's metrics
    while IFS= read -r line; do
        if [[ $line == *"node_id"* ]]; then
            node_id=$(echo $line | grep -o '"node_id":"[^"]*"' | cut -d'"' -f4)
            status=$(echo $line | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
            latency=$(echo $line | grep -o '"latency":[0-9.]*' | cut -d':' -f2)
            bandwidth=$(echo $line | grep -o '"bandwidth":[0-9.]*' | cut -d':' -f2)
            packet_loss=$(echo $line | grep -o '"packet_loss":[0-9.]*' | cut -d':' -f2)
            signal_strength=$(echo $line | grep -o '"signal_strength":[0-9.-]*' | cut -d':' -f2)
            
            echo "│ Node: $node_id"
            echo "│ Status: $(display_node_status $status)"
            echo "│ Latency: ${latency}s"
            echo "│ Bandwidth: $(echo "scale=2; $bandwidth/1000000" | bc) Mbps"
            echo "│ Packet Loss: $(echo "scale=2; $packet_loss*100" | bc)%"
            echo "│ Signal: ${signal_strength}dBm"
            echo "├──────────────────────────────────────────────┤"
        fi
    done <<< "$metrics"
    
    echo "└──────────────────────────────────────────────┘"
}

# Main monitoring loop
while true; do
    # Clear screen
    clear
    
    # Get metrics from the mesh monitor
    metrics=$(curl -s http://localhost:8080/metrics)
    
    # Display metrics
    display_metrics "$metrics"
    
    # Wait before next update
    sleep 5
done 