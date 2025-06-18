# 🔧 Nightwatch Chat Scripts

## 📜 Available Scripts

### 🚀 `deploy-pi-zero.sh`
**Complete Pi Zero 2 W deployment and optimization script**

**Usage:**
```bash
chmod +x scripts/deploy-pi-zero.sh
./scripts/deploy-pi-zero.sh
```

**What it does:**
- ✅ System optimization for 100 users
- ✅ Swap configuration (512MB)
- ✅ Network parameter tuning
- ✅ GPU memory optimization
- ✅ Docker optimization for ARM
- ✅ Service cleanup (bluetooth, etc.)
- ✅ Full Nightwatch deployment
- ✅ Verification and monitoring setup

**First-time setup on Pi Zero 2 W - use this script!**

---

### ⚡ `update-nightwatch.sh`
**Quick update script for code changes**

**Usage:**
```bash
chmod +x scripts/update-nightwatch.sh
./scripts/update-nightwatch.sh
```

**What it does:**
- 🔄 Stops containers
- 🔨 Rebuilds with latest code
- ▶️ Restarts services
- 📊 Shows status

**For updates after initial deployment**

---

### 📊 `monitor.sh`
**Real-time resource monitoring**

**Usage:**
```bash
chmod +x scripts/monitor.sh
./scripts/monitor.sh
```

**Shows:**
- 💾 Memory usage
- 🖥️ CPU usage
- 💿 Disk usage
- 🐳 Container stats
- 🌐 Connection counts
- 📈 Load averages

**Run regularly to track performance**

---

## 🎯 Quick Commands

### First Time Setup (Pi Zero 2 W):
```bash
# 1. Extract project
tar -xzf nightwatch-optimized.tar.gz
cd Mesh-Nightwatch

# 2. Run full deployment
./scripts/deploy-pi-zero.sh

# 3. Monitor
./scripts/monitor.sh
```

### Code Updates:
```bash
# Quick rebuild and restart
./scripts/update-nightwatch.sh
```

### Monitoring:
```bash
# One-time check
./scripts/monitor.sh

# Continuous monitoring
watch ./scripts/monitor.sh

# Docker stats
watch docker stats
```

### Troubleshooting:
```bash
# Check logs
docker-compose logs

# Restart everything
docker-compose restart

# Clean rebuild
./scripts/update-nightwatch.sh

# Emergency cleanup
docker system prune -af
```

## 📋 Performance Expectations

| Users | Memory Usage | Performance |
|-------|--------------|-------------|
| 25    | ~80MB       | Smooth      |
| 50    | ~120MB      | Good        |
| 75    | ~180MB      | Manageable  |
| 100   | ~250MB      | At capacity |

## 🔧 Manual Commands

If you prefer manual control:

```bash
# System optimization
sudo dphys-swapfile swapoff
sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
sudo dphys-swapfile setup && sudo dphys-swapfile swapon

# Deploy Nightwatch
docker-compose down --volumes
docker-compose build --no-cache
docker-compose up -d

# Monitor
docker stats
```

## 🆘 Emergency Recovery

If something goes wrong:

```bash
# Stop everything
docker-compose down

# Clean Docker
docker system prune -af --volumes

# Restart deployment
./scripts/deploy-pi-zero.sh
``` 