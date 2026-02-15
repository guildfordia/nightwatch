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

.PHONY: install run stop test update status logs help clean monitor blink

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
update:
	@echo "====================================="
	@echo "  Nightwatch — Update"
	@echo "====================================="
	@echo ""
	@echo "[1/4] Stopping services..."
	@$(MAKE) stop 2>/dev/null || true
	@echo ""
	@echo "[2/4] Pulling latest code..."
	@git pull
	@echo ""
	@echo "[3/4] Rebuilding Docker images..."
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
