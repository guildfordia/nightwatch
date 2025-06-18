# 🚀 Nightwatch Chat - 100 Users on Pi Zero 2 W

## 📊 Performance Targets

| Component | Memory Usage | Expected Load |
|-----------|--------------|---------------|
| ngircd | ~100-150MB | 100 IRC connections |
| Go Bridge | ~50-80MB | 100 WebSocket connections |
| nginx | ~20-30MB | HTTP serving + WS proxy |
| **Total** | **~170-260MB** | **Available: 512MB** |

## ⚙️ Pi Zero 2 W Optimizations

### 1. System-Level Setup

```bash
# Enable swap (on Pi Zero 2 W)
sudo dphys-swapfile swapoff
sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

# Optimize kernel parameters
echo 'net.core.somaxconn = 1024' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_max_syn_backlog = 1024' | sudo tee -a /etc/sysctl.conf
echo 'net.core.netdev_max_backlog = 1000' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Disable unnecessary services
sudo systemctl disable bluetooth
sudo systemctl disable triggerhappy
sudo systemctl disable avahi-daemon
```

### 2. Docker Optimizations

```bash
# Set Docker daemon limits
sudo cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1m",
    "max-file": "1"
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF

sudo systemctl restart docker
```

### 3. Build Optimized Version

```bash
# Clean build
docker-compose down --volumes
docker system prune -af

# Build with optimizations
docker-compose build --no-cache
docker-compose up -d
```

## 📈 Monitoring & Limits

### Real-time Monitoring
```bash
# Run monitoring script
chmod +x scripts/monitor.sh
./scripts/monitor.sh

# Watch container resources
watch docker stats

# Monitor connections
watch 'echo "Active connections: $(ss -tun | grep :80 | wc -l)"'
```

### Connection Limits
- **Max WebSocket connections**: 100
- **Max IRC connections**: 100  
- **Max connections per IP**: 25
- **Channel user limit**: 100
- **Idle timeout**: 15 minutes

## 🔧 Performance Tuning

### Go Bridge Features:
- **Memory efficient**: ~500KB per connection
- **Connection pooling**: Shared IRC connections
- **Automatic cleanup**: Dead connection removal
- **Rate limiting**: Built-in message throttling

### ngircd Optimizations:
- **Reduced limits**: Shorter nicks, topics, away messages
- **Faster timeouts**: Aggressive idle disconnection
- **Single channel**: Limited to #nightwatch only
- **No auth required**: Faster connections

### nginx Optimizations:
- **Connection keepalive**: Reuse connections
- **Static file caching**: 1-hour cache headers  
- **Upstream pooling**: Connection pooling to bridge
- **Timeout optimization**: Fast failure detection

## 🚨 Warning Signs

Watch for these indicators of overload:

```bash
# Memory pressure
free -h | grep Mem | awk '{if($7 < 50) print "WARNING: Low memory!"}'

# High CPU usage
top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{if($1 < 20) print "WARNING: High CPU!"}'

# Connection errors
docker logs irc-bridge | grep -i error | tail -5

# IRC server status
docker exec ngircd killall -USR1 ngircd  # Dump stats to logs
docker logs ngircd | tail -10
```

## 📊 Expected Performance

### Load Test Results (estimated):
- **25 users**: Smooth operation (~80MB RAM)
- **50 users**: Good performance (~120MB RAM)  
- **75 users**: Manageable load (~180MB RAM)
- **100 users**: At capacity (~250MB RAM)
- **125+ users**: Overload risk ⚠️

### Network Bandwidth:
- **Per user**: ~1-5KB/s average
- **100 users**: ~100-500KB/s total
- **Wi-Fi limit**: ~10MB/s (plenty of headroom)

## 🔄 Scaling Strategies

If you need more than 100 users:

1. **Multiple Pi Zeros**: Federation/linking
2. **Pi 4 upgrade**: 4GB+ RAM model
3. **Connection pooling**: Share IRC connections
4. **Message batching**: Reduce per-message overhead
5. **External load balancer**: Multiple bridge instances

## 🛠️ Troubleshooting

### Common Issues:

**Out of Memory:**
```bash
# Check swap usage
swapon --show
# Restart containers with limits
docker-compose restart
```

**Too many connections:**
```bash
# Check current limits
ulimit -n
# Check container connections
docker exec irc-bridge ss -tun | wc -l
```

**IRC server overload:**
```bash
# Restart IRC server
docker-compose restart ngircd
# Check IRC logs
docker logs ngircd | tail -20
```

## 📝 Maintenance

### Daily:
- Check `./scripts/monitor.sh` output
- Monitor Docker logs for errors
- Verify all containers running

### Weekly:
- Clean Docker system: `docker system prune`
- Check available storage space
- Update container images if needed

### Monthly:
- Review user count trends
- Consider hardware upgrades if consistently at capacity
- Test backup/restore procedures 