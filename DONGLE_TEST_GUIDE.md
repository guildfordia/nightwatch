# WiFi Dongle Testing Guide for BATMAN Mesh

## Current Greennode Status
- **Working dongle**: Qualcomm Atheros AR9271 (MAC: 24:ec:99:bf:ad:5c)
- **Driver**: ath9k_htc ✅ COMPATIBLE
- **BATMAN**: Active but no neighbors detected

## Compatible Chipsets for BATMAN Mesh

### ✅ BEST (Known Working):
1. **Atheros AR9271** (ath9k_htc) - Currently installed on greennode
2. **Atheros AR9170** (carl9170)
3. **Ralink RT3070/RT3072** (rt2800usb)
4. **Ralink RT5370** (rt2800usb)
5. **MediaTek MT7601U** (mt7601u)

### ⚠️ MAYBE (Depends on driver):
- Realtek RTL8188CUS (rtl8192cu) - hit or miss
- Realtek RTL8192EU (rtl8xxxu) - limited support

### ❌ NOT COMPATIBLE:
- Realtek RTL8812AU/RTL8814AU - proprietary drivers, no mesh
- Broadcom chipsets - generally poor Linux mesh support

## Step-by-Step Dongle Testing Process

### 1. Check Current Dongle
```bash
ssh user@192.168.1.157
lsusb
sudo /sbin/iw phy | grep -A 10 "Supported interface modes"
```

**Look for**: IBSS, mesh point, or monitor modes

### 2. Swap Dongle Procedure
1. **SSH into greennode**: `ssh user@192.168.1.157`
2. **Stop BATMAN mesh**:
   ```bash
   cd ~/nightwatch
   sudo make mesh-reset
   # or manually:
   sudo batctl if del wlan1
   sudo ip link set wlan1 down
   ```
3. **Power off Pi**: `sudo poweroff`
4. **Physically swap USB WiFi dongle**
5. **Power on Pi** and wait for boot
6. **SSH back in** and test new dongle

### 3. Test New Dongle
Run this script on the Pi:

```bash
#!/bin/bash
echo "=== USB Devices ==="
lsusb
echo ""
echo "=== WiFi Interfaces ==="
ip link show | grep -E "wlan|bat"
echo ""
echo "=== Chipset Detection ==="
lsusb -t | grep -i "driver"
echo ""
echo "=== Supported Modes ==="
sudo /sbin/iw phy | grep -A 10 "Supported interface modes"
echo ""
echo "=== BATMAN Status ==="
sudo batctl if
sudo batctl o
echo ""
echo "=== Mesh Neighbors ==="
sudo /sbin/iw dev wlan1 scan | grep -E "SSID|signal"
```

### 4. Key Checks

✅ **Dongle is GOOD if**:
- Shows in `lsusb` output
- Creates wlan1 interface
- Supports "IBSS" or "mesh point" modes
- Driver loads without errors in `dmesg | tail -50`
- Can be added to bat0: `sudo batctl if add wlan1`

❌ **Dongle is BAD if**:
- Not detected in `lsusb`
- No wlan1 interface created
- Only supports "managed" mode (no IBSS/mesh)
- Driver errors in `dmesg`
- `batctl if add wlan1` fails

## Quick Test Commands

### From your Mac:
```bash
# Test greennode
ssh user@192.168.1.157 "lsusb && echo === && sudo batctl if && sudo batctl o"

# Test blacknode
ssh user@192.168.1.181 "lsusb && echo === && sudo batctl if && sudo batctl o"
```

### Check if nodes can see each other:
```bash
# From greennode to blacknode
ssh user@192.168.1.157 "ping -c 3 192.168.199.101"

# From blacknode to greennode
ssh user@192.168.1.181 "ping -c 3 192.168.199.102"
```

## Common Issues

### Issue: "No such device" when adding to bat0
**Cause**: Interface not in correct mode
**Fix**:
```bash
sudo ip link set wlan1 down
sudo /sbin/iw wlan1 set type ibss
sudo ip link set wlan1 up
sudo batctl if add wlan1
```

### Issue: Dongle not detected at all
**Cause**: Broken dongle or power issue
**Fix**: Try different USB port or powered USB hub (Pi Zero 2 W has limited power)

### Issue: Driver not loading
**Cause**: Missing firmware or incompatible chipset
**Fix**: Check `dmesg | grep firmware` and install if needed

## Recommended Dongles to Buy

If you need to purchase new dongles:
1. **ALFA AWUS036NHA** - AR9271 chipset, excellent range
2. **Panda Wireless PAU05** - Ralink RT5370, budget-friendly
3. **TP-Link TL-WN722N v1** - AR9271 (⚠️ v2/v3 use Realtek - avoid!)

## Testing Matrix

| Dongle | Chipset | Driver | IBSS | Mesh | Works? |
|--------|---------|--------|------|------|--------|
| Current | AR9271 | ath9k_htc | ✅ | ✅ | ✅ YES |
| Dongle 2 | ? | ? | ? | ? | ? |
| Dongle 3 | ? | ? | ? | ? | ? |

Fill in as you test each dongle!
