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
INSTALL_DIR := /opt/nightwatch

# Auto-detect docker compose v2 vs v1
DC := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

.PHONY: install run stop test update status logs help clean monitor

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
	@# Start Docker apps
	@echo "[+] Starting app services..."
	@cd $(INSTALL_DIR) && $(DC) --env-file $(ENV_FILE) up -d
	@sleep 2
	@echo ""
	@# Quick connectivity check
	@echo "[+] Quick connectivity check..."
	@. $(INSTALL_DIR)/$(ENV_FILE) 2>/dev/null; \
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		eval ip=\$$PI$${i}_MESH_IP; \
		eval name=\$$PI$${i}_SERVER_NAME; \
		[ -z "$$ip" ] && continue; \
		if ip -4 addr show 2>/dev/null | grep -q "$$ip"; then \
			echo "  [*] $$ip ($$name) — this node"; \
		elif ping -c 1 -W 1 "$$ip" >/dev/null 2>&1; then \
			rtt=$$(ping -c 1 -W 1 "$$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//'); \
			echo "  [+] $$ip ($$name) — reachable ($$rtt)"; \
		else \
			echo "  [-] $$ip ($$name) — unreachable"; \
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
	@cd $(INSTALL_DIR) && $(DC) --env-file $(ENV_FILE) down 2>/dev/null || true
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
	@echo "[1/5] Stopping services..."
	@$(MAKE) stop 2>/dev/null || true
	@echo ""
	@echo "[2/5] Pulling latest code..."
	@git pull
	@echo ""
	@echo "[3/5] Syncing to $(INSTALL_DIR)..."
	@sudo rsync -a --delete \
		--exclude='.git' \
		--exclude='.env' \
		--exclude='ngircd/ngircd.conf' \
		--exclude='*.log' \
		--exclude='.DS_Store' \
		--exclude='.firstboot-done' \
		. $(INSTALL_DIR)/
	@sudo chmod +x $(INSTALL_DIR)/scripts/*.sh
	@echo "[+] Code synced (node config preserved)"
	@echo ""
	@echo "[4/5] Rebuilding Docker images..."
	@cd $(INSTALL_DIR) && sudo $(DC) --env-file $(ENV_FILE) build
	@echo ""
	@echo "[5/5] Restarting..."
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
		sudo $(INSTALL_DIR)/scripts/mesh-fix.sh status 2>/dev/null || \
		echo "[!] Mesh status unavailable"
	@echo ""
	@echo "== Docker Services =="
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (docker not running)"

# -------- logs --------
logs:
	@cd $(INSTALL_DIR) && $(DC) logs -f

# -------- clean --------
clean:
	@echo "[+] Removing containers and volumes..."
	@cd $(INSTALL_DIR) && $(DC) --env-file $(ENV_FILE) down -v 2>/dev/null || true
	@docker system prune -f
	@echo "[+] Clean"

# -------- monitor --------
monitor:
	@while true; do \
		clear; \
		echo "=== NIGHTWATCH MONITOR === ($$(date))  Ctrl+C to exit"; \
		echo ""; \
		sudo scripts/mesh-fix.sh status 2>/dev/null || \
			sudo $(INSTALL_DIR)/scripts/mesh-fix.sh status 2>/dev/null || true; \
		echo ""; \
		echo "== Docker Services =="; \
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true; \
		sleep 5; \
	done
