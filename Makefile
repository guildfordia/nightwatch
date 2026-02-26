# Nightwatch — mesh network + chat on Raspberry Pi
#
# Usage:
#   make install    First-time setup (packages, config, Docker images)
#   make run        Start everything (mesh + apps)
#   make stop       Stop everything
#   make test       Run all tests (mesh, Docker, services)
#   make update     Pull latest code, rebuild, restart
#   make status     Show mesh and service status
#   make logs       Follow Docker logs

# -------- Config --------
ENV_FILE   := .env

# Auto-detect docker compose v2 vs v1
DC := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

.PHONY: install run stop test update status logs help clean monitor blink image sdcard info router

.DEFAULT_GOAL := help

# ============================================================
#  Main targets
# ============================================================

help:
	@echo "Nightwatch — mesh chat on Raspberry Pi"
	@echo ""
	@echo "  make install   First-time setup (run once per Pi)"
	@echo "  make run       Start mesh + apps"
	@echo "  make stop      Stop everything"
	@echo "  make test      Test everything (mesh, Docker, services)"
	@echo "  make update    Pull latest code + rebuild + restart"
	@echo "  make status    Show mesh & service status"
	@echo "  make logs      Follow Docker logs"
	@echo "  make clean     Remove containers and volumes"
	@echo "  make monitor   Live dashboard (refreshes every 5s)"
	@echo "  make blink     Blink onboard LED to identify this Pi"
	@echo "  make router    Configure GL.iNet router (can run separately)"
	@echo "  make image     Prepare this Pi for SD card cloning (golden image)"
	@echo "  make sdcard    Prepare a flashed SD card for a node (run on laptop)"
	@echo "  make info      Show detailed node info (network, DNS, system)"
	@echo ""
	@echo "First time on a new Pi:"
	@echo "  git clone https://github.com/guildfordia/nightwatch.git"
	@echo "  cd nightwatch"
	@echo "  make install"
	@echo "  make run"
	@echo "  make test"

# -------- install --------
# Full setup: packages, Docker, mesh, config, systemd, build images
install:
	@echo "====================================="
	@echo "  Nightwatch — Install"
	@echo "====================================="
	@sudo scripts/setup-rpi.sh $(ARGS)

# -------- run --------
# Start mesh network + Docker apps
run:
	@echo "====================================="
	@echo "  Nightwatch — Starting"
	@echo "====================================="
	@# Ensure scripts are executable
	@chmod +x scripts/*.sh 2>/dev/null || true
	@# Ensure mesh service is installed
	@if [ ! -f /etc/systemd/system/nightwatch-mesh.service ]; then \
		echo "[!] Not installed yet. Run 'make install' first."; \
		exit 1; \
	fi
	@# Start mesh
	@echo "[+] Starting mesh network..."
	@sudo systemctl daemon-reload
	@sudo systemctl enable nightwatch-mesh.service 2>/dev/null || true
	@sudo systemctl start nightwatch-mesh.service
	@sleep 3
	@sudo systemctl --no-pager --full status nightwatch-mesh.service || true
	@echo ""
	@# Start node discovery
	@echo "[+] Starting node discovery..."
	@sudo systemctl start nightwatch-discovery.service 2>/dev/null || true
	@echo ""
	@# Fix ngircd/ permissions (Docker creates it as root) and generate config
	@sudo chown -R $$(id -u):$$(id -g) ngircd/ 2>/dev/null || true
	@scripts/setup-distributed-irc.sh
	@echo ""
	@# Start Docker apps
	@echo "[+] Starting app services..."
	@$(DC) --env-file $(ENV_FILE) up -d
	@sleep 2
	@echo ""
	@# Quick connectivity check — scan all possible mesh IPs (192.168.199.101-120)
	@echo "[+] Quick connectivity check..."
	@. ./$(ENV_FILE) 2>/dev/null; \
	LOCAL=$${MESH_IP%/*}; \
	for i in $$(seq 1 20); do \
		ip="192.168.199.$$((100 + i))"; \
		if [ "$$ip" = "$$LOCAL" ]; then \
			echo "  [*] $$ip (node $$i) — this node"; \
		elif ping -c 1 -W 1 "$$ip" >/dev/null 2>&1; then \
			rtt=$$(ping -c 1 -W 1 "$$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//'); \
			echo "  [+] $$ip (node $$i) — reachable ($$rtt)"; \
		fi; \
	done
	@echo ""
	@echo "[+] Docker services:"
	@docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || echo "  (docker not running)"
	@echo ""
	@echo "====================================="
	@echo "  Nightwatch is running"
	@echo "====================================="

# -------- stop --------
stop:
	@echo "[+] Stopping Nightwatch..."
	@# Stop containers one at a time (avoids memory spike on Pi 3 with 1GB RAM)
	@$(DC) --env-file $(ENV_FILE) stop -t 15 nginx 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) stop -t 15 irc-bridge 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) stop -t 15 ngircd 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) rm -f nginx irc-bridge ngircd 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) down 2>/dev/null || true
	@sudo systemctl stop nightwatch-discovery.service 2>/dev/null || true
	@sudo systemctl stop nightwatch-mesh.service 2>/dev/null || true
	@echo "[+] Nightwatch stopped"

# -------- test --------
# Full test suite: mesh health, Docker services, cross-node connectivity
test:
	@echo "====================================="
	@echo "  Nightwatch — Test Suite"
	@echo "====================================="
	@echo ""
	@sudo scripts/test-mesh.sh
	@echo ""
	@scripts/test-docker.sh

# -------- update --------
# Pull latest code, rebuild Docker images, restart
# NOTE: git pull runs BEFORE stopping anything — make stop kills wpa_supplicant
# which takes down the internet connection needed for git pull.
update:
	@echo "====================================="
	@echo "  Nightwatch — Update"
	@echo "====================================="
	@echo ""
	@echo "[1/4] Pulling latest code..."
	@if git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then \
		git pull; \
	else \
		echo "  [!] Remote unreachable (offline/mesh-only) — skipping git pull"; \
		echo "  [i] Using code already on disk"; \
	fi
	@# Ensure scripts are executable (git can lose +x on some setups)
	@chmod +x scripts/*.sh 2>/dev/null || true
	@echo ""
	@echo "[2/4] Stopping containers..."
	@$(DC) --env-file $(ENV_FILE) stop -t 15 nginx 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) stop -t 15 irc-bridge 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) stop -t 15 ngircd 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) rm -f nginx irc-bridge ngircd 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) down 2>/dev/null || true
	@echo ""
	@echo "[3/4] Rebuilding Docker images..."
	@# Free memory before build — Go compiler is heavy on Pi 3 (1GB RAM)
	@sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
	@$(DC) --env-file $(ENV_FILE) build
	@echo ""
	@echo "[4/4] Restarting..."
	@$(MAKE) run
	@echo ""
	@echo "[+] Update complete."

# -------- status --------
status:
	@echo "====================================="
	@echo "  Nightwatch — Status"
	@echo "====================================="
	@echo ""
	@sudo scripts/mesh-fix.sh status 2>/dev/null || \
		echo "[!] Mesh status unavailable"
	@echo ""
	@echo "== Docker Services =="
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (docker not running)"

# -------- logs --------
logs:
	@$(DC) logs -f

# -------- clean --------
clean:
	@echo "[+] Removing containers and volumes..."
	@$(DC) --env-file $(ENV_FILE) down -v 2>/dev/null || true
	@docker system prune -f
	@echo "[+] Clean"

# -------- blink --------
# Blink the onboard ACT LED to physically identify this Pi
blink:
	@echo "Blinking LED for 10 seconds — look for the flashing green light..."
	@sudo sh -c 'LED=/sys/class/leds/ACT; \
		if [ ! -d "$$LED" ]; then LED=/sys/class/leds/led0; fi; \
		if [ ! -d "$$LED" ]; then echo "No LED found at /sys/class/leds/ACT or led0"; exit 1; fi; \
		ORIG=$$(cat "$$LED/trigger" | grep -oP "\[\K[^\]]+"); \
		echo none > "$$LED/trigger"; \
		for i in $$(seq 1 20); do \
			echo 1 > "$$LED/brightness"; sleep 0.25; \
			echo 0 > "$$LED/brightness"; sleep 0.25; \
		done; \
		echo "$$ORIG" > "$$LED/trigger"'
	@echo "Done."

# -------- monitor --------
monitor:
	@while true; do \
		clear; \
		echo "=== NIGHTWATCH MONITOR === ($$(date))  Ctrl+C to exit"; \
		echo ""; \
		sudo scripts/mesh-fix.sh status 2>/dev/null || true; \
		echo ""; \
		echo "== Docker Services =="; \
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true; \
		sleep 5; \
	done

# -------- image --------
# Prepare this Pi as a golden image for cloning (run ON the Pi)
image:
	@echo "====================================="
	@echo "  Nightwatch — Build Golden Image"
	@echo "====================================="
	@sudo scripts/build-image.sh

# -------- router --------
# Configure GL.iNet router (run on the Pi with router plugged into eth0)
router:
	@echo "====================================="
	@echo "  Nightwatch — Router Setup"
	@echo "====================================="
	@sudo scripts/setup-router.sh

# -------- sdcard --------
# Prepare a flashed SD card for a specific node (run on your laptop)
# Usage: make sdcard NODE=1
#        make sdcard NODE=2 GATEWAY=true
sdcard:
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make sdcard NODE=<number> [GATEWAY=true]"; \
		echo ""; \
		echo "Examples:"; \
		echo "  make sdcard NODE=1"; \
		echo "  make sdcard NODE=2"; \
		echo "  make sdcard NODE=3 GATEWAY=true"; \
		exit 1; \
	fi
	@scripts/prepare-sdcard.sh $(NODE) $(if $(filter true,$(GATEWAY)),--gateway,)

# -------- info --------
# Print detailed node information (network, DNS, system, mesh, Docker)
info:
	@echo "====================================="
	@echo "  Nightwatch — Node Info"
	@echo "====================================="
	@echo ""
	@echo "== Identity =="
	@echo "  Hostname:  $$(hostname)"
	@if [ -f $(ENV_FILE) ]; then \
		. ./$(ENV_FILE) 2>/dev/null; \
		echo "  Node:      #$$PI_NUMBER"; \
		echo "  Mesh IP:   $$MESH_IP"; \
		echo "  Gateway:   $$MESH_GATEWAY"; \
		echo "  Mesh ID:   $$MESH_ID"; \
		echo "  Mesh freq: $$FREQ MHz"; \
	else \
		echo "  [!] No .env file found — run 'make install' first"; \
	fi
	@echo ""
	@echo "== System =="
	@echo "  OS:        $$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
	@echo "  Kernel:    $$(uname -r)"
	@echo "  Arch:      $$(uname -m)"
	@echo "  Uptime:    $$(uptime -p 2>/dev/null || uptime)"
	@echo "  Memory:    $$(free -h | awk '/^Mem:/ {printf "%s used / %s total", $$3, $$2}')"
	@echo "  Disk:      $$(df -h / | awk 'NR==2 {printf "%s used / %s total (%s)", $$3, $$2, $$5}')"
	@echo "  CPU temp:  $$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f°C", $$1/1000}' || echo 'N/A')"
	@echo "  Load:      $$(cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3)"
	@echo ""
	@echo "== Network Interfaces =="
	@echo "--- wlan0 (internet/SSH) ---"
	@ip addr show wlan0 2>/dev/null | grep -E 'state|inet ' | sed 's/^/  /' || echo "  not found"
	@SSID=$$(iw dev wlan0 link 2>/dev/null | grep SSID | awk '{print $$2}'); \
		if [ -n "$$SSID" ]; then echo "  SSID: $$SSID"; else echo "  SSID: not connected"; fi
	@echo "--- wlan1 (mesh radio) ---"
	@ip addr show wlan1 2>/dev/null | grep -E 'state|inet ' | sed 's/^/  /' || echo "  not found"
	@iw dev wlan1 info 2>/dev/null | grep -E 'type|channel' | sed 's/^/  /' || true
	@echo "--- bat0 (batman-adv) ---"
	@ip addr show bat0 2>/dev/null | grep -E 'state|inet ' | sed 's/^/  /' || echo "  not found"
	@sudo batctl meshif bat0 if 2>/dev/null | sed 's/^/  /' || true
	@echo "--- br0 (bridge) ---"
	@ip addr show br0 2>/dev/null | grep -E 'state|inet ' | sed 's/^/  /' || echo "  not found"
	@echo "--- eth0 (AP/router) ---"
	@ip addr show eth0 2>/dev/null | grep -E 'state|inet ' | sed 's/^/  /' || echo "  not found"
	@echo ""
	@echo "== Routing =="
	@ip route | sed 's/^/  /'
	@echo ""
	@echo "== DNS =="
	@echo "  /etc/resolv.conf:"
	@cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$$' | sed 's/^/    /'
	@echo "  immutable: $$(lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i' && echo 'yes' || echo 'no')"
	@TSDNS=$$(tailscale debug prefs 2>/dev/null | grep -i 'CorpDNS' | head -1) || true; \
		if command -v tailscale >/dev/null 2>&1; then \
			ACCEPT=$$(tailscale debug prefs 2>/dev/null | grep 'CorpDNS' | head -1 || echo 'unknown'); \
			echo "  Tailscale accept-dns: $$ACCEPT"; \
		fi
	@echo "  DNS test:  $$(nslookup google.com 2>/dev/null | grep -q 'Address' && echo 'OK' || echo 'FAILED')"
	@echo ""
	@echo "== Tailscale =="
	@if command -v tailscale >/dev/null 2>&1; then \
		tailscale status 2>/dev/null | head -5 | sed 's/^/  /'; \
		echo "  IP: $$(tailscale ip -4 2>/dev/null || echo 'N/A')"; \
	else \
		echo "  not installed"; \
	fi
	@echo ""
	@echo "== Mesh Peers =="
	@if command -v batctl >/dev/null 2>&1; then \
		echo "  Originators:"; \
		sudo batctl meshif bat0 o 2>/dev/null | head -10 | sed 's/^/    /' || echo "    none"; \
		echo "  Gateway list:"; \
		sudo batctl meshif bat0 gwl 2>/dev/null | sed 's/^/    /' || echo "    none"; \
	else \
		echo "  batctl not installed"; \
	fi
	@echo ""
	@echo "== Mesh Nodes (ping scan) =="
	@. ./$(ENV_FILE) 2>/dev/null; \
	LOCAL=$${MESH_IP%/*}; \
	for i in $$(seq 1 20); do \
		ip="192.168.199.$$((100 + i))"; \
		if [ "$$ip" = "$$LOCAL" ]; then \
			echo "  [*] $$ip (node $$i) — this node"; \
		elif ping -c 1 -W 1 "$$ip" >/dev/null 2>&1; then \
			rtt=$$(ping -c 1 -W 1 "$$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//'); \
			echo "  [+] $$ip (node $$i) — reachable ($$rtt)"; \
		fi; \
	done
	@echo ""
	@echo "== Docker =="
	@echo "  Compose: $(DC)"
	@docker --version 2>/dev/null | sed 's/^/  /' || echo "  not installed"
	@echo "  Containers:"
	@docker ps -a --format "    {{.Names}}: {{.Status}} ({{.Image}})" 2>/dev/null || echo "    (docker not running)"
	@echo "  Images:"
	@docker images --format "    {{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | grep -i nightwatch || echo "    none"
	@echo "  Networks:"
	@docker network ls --format "    {{.Name}} ({{.Driver}})" 2>/dev/null | grep -v 'bridge\|host\|none' || echo "    default only"
	@echo ""
	@echo "== Systemd Services =="
	@for svc in nightwatch-mesh nightwatch-discovery nightwatch-docker nightwatch-nodeconfig nightwatch-firstboot; do \
		STATUS=$$(systemctl is-active $$svc.service 2>/dev/null || echo "not found"); \
		ENABLED=$$(systemctl is-enabled $$svc.service 2>/dev/null || echo "-"); \
		printf "  %-30s %s (%s)\n" "$$svc" "$$STATUS" "$$ENABLED"; \
	done
	@echo ""
	@echo "== Internet Connectivity =="
	@echo -n "  ping 8.8.8.8:   " && (ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "OK" || echo "FAILED")
	@echo -n "  ping google.com: " && (ping -c 1 -W 3 google.com >/dev/null 2>&1 && echo "OK" || echo "FAILED")
	@echo -n "  curl https:      " && (curl -sf --max-time 5 https://ifconfig.me 2>/dev/null && echo "" || echo "FAILED")
	@echo ""
	@echo "====================================="
