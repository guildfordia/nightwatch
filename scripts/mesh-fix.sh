#!/bin/bash
# Fixed mesh setup script for IBSS with static ARP

IFACE=wlan1

# Determine node configuration based on hostname
case $(hostname) in
    bluenode)
        MESH_IP="192.168.199.101/24"
        ARP_ENTRIES=(
            "192.168.199.102 90:de:80:cc:24:98"
            "192.168.199.103 90:de:80:c7:7d:4c"
        )
        ;;
    blacknode)
        MESH_IP="192.168.199.102/24"
        ARP_ENTRIES=(
            "192.168.199.101 90:de:80:c7:7d:17"
            "192.168.199.103 90:de:80:c7:7d:4c"
        )
        ;;
    whitenode)
        MESH_IP="192.168.199.103/24"
        ARP_ENTRIES=(
            "192.168.199.101 90:de:80:c7:7d:17"
            "192.168.199.102 90:de:80:cc:24:98"
        )
        ;;
    *)
        echo "Unknown hostname: $(hostname)"
        exit 1
        ;;
esac

case "$1" in
    start)
        echo "Starting mesh network on $IFACE..."

        # 1. Bring down interface first
        ip link set $IFACE down

        # 2. Set IBSS mode
        iw dev $IFACE set type ibss

        # 3. Bring up interface
        ip link set $IFACE up

        # 4. Wait for interface to be ready
        sleep 2

        # 5. Join IBSS network
        iw dev $IFACE ibss join batmesh 2412 fixed-freq 02:12:34:56:78:9A

        # 6. Wait for IBSS to establish
        sleep 2

        # 7. Add IP address
        ip addr flush dev $IFACE
        ip addr add $MESH_IP dev $IFACE

        # 8. Add static ARP entries after network is up
        for entry in "${ARP_ENTRIES[@]}"; do
            ip_mac=($entry)
            echo "Adding ARP: ${ip_mac[0]} -> ${ip_mac[1]}"
            arp -s ${ip_mac[0]} ${ip_mac[1]} || echo "Warning: Failed to add ARP entry"
        done

        echo "Mesh network started on $IFACE with IP ${MESH_IP%/*}"
        ;;

    stop)
        echo "Stopping mesh network on $IFACE..."
        iw dev $IFACE ibss leave
        ip addr flush dev $IFACE
        ip link set $IFACE down
        echo "Mesh network stopped"
        ;;

    status)
        echo "=== Interface Status ==="
        ip addr show $IFACE
        echo ""
        echo "=== IBSS Status ==="
        iw dev $IFACE info
        echo ""
        echo "=== IBSS Stations ==="
        iw dev $IFACE station dump
        echo ""
        echo "=== ARP Table ==="
        arp -n | grep "192.168.199"
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac