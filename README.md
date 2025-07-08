# 🌙 NIGHTWATCH - Raspberry Pi Installation Guide

![Nightwatch Banner](https://img.shields.io/badge/NIGHTWATCH-Mesh%20Network%20Terminal-blue?style=for-the-badge)

A resilient chat system designed for off-grid communication using Batman Advanced mesh networking protocol. Zero infrastructure required - just power and Raspberry Pis.

## 🎯 What is Nightwatch?

Nightwatch creates a **decentralized mesh network** where multiple Raspberry Pi devices automatically discover each other and form a self-healing communication network. Perfect for:

- **Emergency Communications** - When internet/cellular is down
- **Remote Areas** - No infrastructure required 
- **Privacy-focused Messaging** - All traffic stays local
- **Event Coordination** - Festivals, protests, disaster response
- **Off-grid Communities** - Sustainable communication

## 🔧 Features

- ✅ **Zero-infrastructure messaging** - No internet required
- ✅ **Automatic node discovery** - Pis find each other automatically  
- ✅ **Self-healing network topology** - Routes around failed nodes
- ✅ **Terminal-style web interface** - Clean, fast, accessible
- ✅ **Multiple device support** - Phones, tablets, laptops connect via WiFi
- ✅ **Theme support** - Auto/Dark/Light themes
- ✅ **Distributed IRC backend** - Resilient multi-server chat

## 🛠️ Hardware Requirements

### Single Node Setup
- **Raspberry Pi 4** (recommended) or Pi 3B+
- **MicroSD card** (32GB+ recommended, Class 10)
- **Power supply** (official Pi power adapter)
- **WiFi dongle AR9271 Chipset** (USB, for mesh networking - Pi's built-in WiFi serves clients)
- **Router for WiFi hotspot access** (Plugged via Ethernet)

### Multi-Node Mesh Setup  
- **2-4 Raspberry Pi devices** (more nodes = more resilient network)
- Same requirements as above per device
- Nodes will auto-discover within ~300m range (depending on environment)

### Client Devices
- Any device with WiFi and web browser (phones, tablets, laptops)
- Connect to Pi's WiFi hotspot, access web interface

## 📦 Prerequisites

### Raspberry Pi OS Setup
```bash
# Use Raspberry Pi Imager to flash Raspberry Pi OS Lite
# Enable SSH and WiFi in imager settings
# Default user: user, or create your own

# After first boot, update system
sudo apt update && sudo apt upgrade -y
```

### Required Software
The setup script will install these automatically, but here's what you'll need:
- Docker & Docker Compose
- BATMAN mesh networking tools (`batctl`)
- Wireless networking tools
- Git

## 🚀 Quick Installation

### 1. Clone Repository
```bash
# Clone the project
git clone https://github.com/your-repo/nightwatch.git
cd nightwatch
```

### 2. Run Raspberry Pi Setup
```bash
# Make scripts executable and run Pi setup
chmod +x scripts/*.sh
sudo ./scripts/setup-rpi.sh
```

This installs all required packages and sets up Docker. **You may need to log out and back in** for Docker permissions to take effect.

### 3. Prepare Configuration
```bash
# Create environment configuration
make prepare-env
```

This creates a `.env` file. Edit it with your settings:

```bash
nano .env
```

### 4. Configure Your Node
Essential variables to set in `.env`:

```bash
# Mesh Network Configuration
IFACE=wlan1                    # USB WiFi dongle for mesh networking
MESH_ID=nightwatch            # Mesh network name (same for all nodes)
FREQ=2412                     # WiFi frequency (2412 = Channel 1)

# Node Identity (UNIQUE per Pi)
PI_NUMBER=1                   # Unique number: 1, 2, 3, or 4
MESH_IP=192.168.199.101      # Unique IP: .101, .102, .103, .104

# IRC Configuration (same for all nodes)
IRC_LINK_PASSWORD=your-secret-password
DISTRIBUTED_IRC=true

# Service Ports
IRC_PORT=6667
KIWI_PORT=3000
NGINX_PORT=80

# Docker Network
DOCKER_NETWORK=nightwatch-net

# Server Names (distributed IRC)
PI1_SERVER_NAME=blacknode.nightwatch.irc
PI1_MESH_IP=192.168.199.101
PI2_SERVER_NAME=bluenode.nightwatch.irc
PI2_MESH_IP=192.168.199.102
PI3_SERVER_NAME=greennode.nightwatch.irc
PI3_MESH_IP=192.168.199.103
PI4_SERVER_NAME=rednode.nightwatch.irc
PI4_MESH_IP=192.168.199.104
```

### 5. Setup Distributed IRC (Multi-Node)
If setting up multiple Pis for a mesh network:

```bash
# Configure IRC server linking
make setup-distributed-irc
```

### 6. Start Nightwatch
```bash
# Start mesh networking and all services
make start
```

This will:
1. Setup BATMAN mesh networking
2. Configure WiFi interface for mesh mode
3. Start all Docker services (IRC, bridge, web interface)
4. Make the system accessible via web browser

## 🌐 Access Methods

### Web Interface
1. **Connect to Pi's WiFi hotspot** (name depends on your setup)
2. **Open browser** to: `http://192.168.199.100` (or your Pi's IP)
3. **Start chatting!** No account needed

### Direct IRC Access
For power users with IRC clients:
```bash
# Connect directly to IRC server
/server 192.168.199.100 6667
/join #nightwatch
```

## 🔧 Management Commands

```bash
# Start everything
make start

# Stop everything  
make stop

# Restart services
make restart

# View logs
make logs

# Check mesh network status
make batman-status

# Full system restart
make full-restart
```

## 🔍 Troubleshooting

### Check System Status
```bash
# Check if services are running
docker-compose ps

# Check mesh networking
make batman-status

# View service logs
make logs

# Check WiFi interfaces
iwconfig
```

### Common Issues

**"wlan1 interface not found"**
- Ensure USB WiFi dongle is connected
- Some dongles need specific drivers
- Try `lsusb` to see if dongle is detected

**"Mesh network not forming"**
- Check all nodes use same `MESH_ID` and `FREQ`
- Ensure nodes are within WiFi range (~300m outdoors)
- Verify BATMAN module loaded: `lsmod | grep batman`

**"Web interface not loading"**
- Check nginx service: `docker-compose logs nginx`
- Verify port not blocked: `netstat -ln | grep 80`

**"IRC not connecting between nodes"**
- Check IRC link passwords match in all `.env` files
- Verify mesh IPs are reachable: `ping 192.168.199.102`
- Check IRC logs: `docker-compose logs ngircd`

### Reset Network
```bash
# Reset mesh networking
make batman-reset

# Complete reset
make stop
sudo ip link delete bat0 2>/dev/null || true
make start
```

## 🌍 Multi-Node Deployment

### Planning Your Network
- **2 nodes**: Basic redundancy, 1 failure tolerated
- **3 nodes**: Better coverage and reliability
- **4 nodes**: Maximum supported by current config

### Node Configuration
Each Pi needs **unique settings** in `.env`:

**Node 1 (Black):**
```bash
PI_NUMBER=1
MESH_IP=192.168.199.101
```

**Node 2 (Blue):**
```bash
PI_NUMBER=2  
MESH_IP=192.168.199.102
```

**Node 3 (Green):**
```bash
PI_NUMBER=3
MESH_IP=192.168.199.103
```

**Node 4 (Red):**
```bash
PI_NUMBER=4
MESH_IP=192.168.199.104
```

### Deployment Process
1. Configure each Pi with unique settings
2. Deploy to different locations within range
3. Power on - they'll automatically find each other
4. Users connect to any Pi's web interface

## 📱 User Guide

### Connecting
1. **Find the WiFi network** broadcast by any Nightwatch node
2. **Connect** (password may be required - check your setup)
3. **Open browser** to `192.168.199.100` (or node's IP)
4. **Start chatting** immediately!

### Using the Interface
- **Change nickname**: Type `/nick YourName`
- **Toggle user list**: Click "Users" button  
- **Switch themes**: Use theme dropdown (Auto/Dark/Light)
- **View more info**: Click "about" link

### Features
- **Real-time messaging** across all connected nodes
- **Automatic reconnection** if connection drops
- **Mobile-friendly** responsive design
- **Terminal aesthetics** for that authentic feel

## 🔐 Security Considerations

- **Local network only** - traffic doesn't leave the mesh
- **Change default passwords** in `.env` file
- **Use WPA2/WPA3** for WiFi hotspot (configure separately)
- **Physical security** of Raspberry Pi devices
- **Regular updates** of Pi OS and containers

## 📚 Advanced Configuration

### Custom WiFi Hotspot
Set up Pi to broadcast WiFi for client connections:
```bash
# Install hostapd
sudo apt install hostapd

# Configure access point
# (This is beyond scope - see Pi documentation)
```

### Tailscale Integration
For remote access when needed:
```bash
make install-tailscale
```

### Monitoring
```bash
# Watch mesh status
watch -n 5 'make batman-status'

# Monitor traffic
sudo tcpdump -i bat0

# Resource usage
docker stats
```

## 🤝 Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Issues**: [GitHub Issues](https://github.com/your-repo/nightwatch/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-repo/nightwatch/discussions)

---

**Built with ❤️ for decentralized communication**

*"In a world of increasing surveillance and infrastructure dependence, Nightwatch provides a return to peer-to-peer communication that can't be shut down, monitored, or controlled by any central authority."* 