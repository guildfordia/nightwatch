# Nightwatch Makefile — 802.11s + batman-adv mesh with Docker app services

# -------- Config --------
ENV_FILE            := .env
ENV_EXAMPLE_FILE    := .env.example
MESH_SCRIPT         := scripts/mesh-fix.sh
MESH_SERVICE        := scripts/nightwatch-mesh.service
INSTALL_DIR         := /opt/nightwatch

# Prefer Docker Compose v2, fall back if needed
DC ?= docker compose
ifeq (, $(shell which docker-compose 2>/dev/null))
  # keep default "docker compose"
else
  DC := docker-compose
endif

# Tools required on host
REQUIRED_TOOLS = docker ip iw batctl

# -------- Phonies --------
.PHONY: all help prepare-env setup-distributed-irc install-tailscale \
        check-env check-tools up down restart logs clean \
        mesh-setup mesh-reset mesh-status mesh-test mesh-install \
        start stop full-restart monitor \
        test test-go test-lint test-docker test-mesh \
        sdcard build-image update

all: start

help:
	@echo "Nightwatch Makefile"
	@echo ""
	@echo "Mesh: 802.11s + batman-adv (wlan1) with hostapd AP (wlan0)"
	@echo "Apps: IRC server, WebSocket bridge, web interface (Docker)"
	@echo ""
	@echo "First-Time Setup:"
	@echo "  prepare-env            Create $(ENV_FILE) from $(ENV_EXAMPLE_FILE)"
	@echo "  mesh-install           Install systemd service + scripts to $(INSTALL_DIR)"
	@echo "  setup-distributed-irc  Generate linked ngircd config from .env"
	@echo ""
	@echo "Application Control:"
	@echo "  up                     Bring up app services (IRC, bridge, nginx)"
	@echo "  down                   Bring down app services"
	@echo "  restart                Restart app services"
	@echo "  logs                   Follow app logs"
	@echo "  clean                  Remove containers and volumes"
	@echo ""
	@echo "Mesh Network Control:"
	@echo "  mesh-setup             Enable & start mesh service"
	@echo "  mesh-reset             Stop mesh service and clean up"
	@echo "  mesh-status            Show full mesh status (batman-adv, peers, AP, gateways)"
	@echo "  mesh-test              Test connectivity to other nodes"
	@echo ""
	@echo "Combined Operations:"
	@echo "  start                  Start everything (mesh + apps)"
	@echo "  stop                   Stop everything (apps + mesh)"
	@echo "  full-restart           Complete restart"
	@echo "  monitor                Live dashboard (refreshes every 5s)"
	@echo ""
	@echo "Testing:"
	@echo "  test                   Run all tests (Go unit + shellcheck lint)"
	@echo "  test-go                Run Go unit tests (irc-bridge)"
	@echo "  test-lint              Run shellcheck on all bash scripts"
	@echo "  test-docker            Run Docker integration tests (builds, health, connectivity)"
	@echo "  test-mesh              Run mesh integration tests (requires running mesh)"
	@echo "  test-mesh-quick        Quick mesh test (skip IRC cross-node + latency matrix)"
	@echo ""
	@echo "Updates & Deployment:"
	@echo "  update                 Update code + rebuild Docker (keeps node config)"
	@echo "  build-image            Prepare this Pi as a clonable image (run ON the Pi)"
	@echo "  sdcard NODE=<n>        Prepare SD card for node N (e.g. make sdcard NODE=1)"
	@echo "  sdcard NODE=<n> GW=1   Prepare as gateway node (internet sharing)"
	@echo ""
	@echo "Optional:"
	@echo "  install-tailscale      Install Tailscale VPN for remote access"

# -------- Environment Setup --------
prepare-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "[+] Creating $(ENV_FILE) from $(ENV_EXAMPLE_FILE)..."; \
		cp $(ENV_EXAMPLE_FILE) $(ENV_FILE); \
		echo "[!] Please edit $(ENV_FILE) with your node settings."; \
	else \
		echo "[+] $(ENV_FILE) already exists."; \
	fi

setup-distributed-irc: check-env
	@echo "[+] Setting up distributed IRC configuration..."
	@[ -x scripts/setup-distributed-irc.sh ] && scripts/setup-distributed-irc.sh || { \
		echo "[!] scripts/setup-distributed-irc.sh not found or not executable"; }

install-tailscale:
	@echo "[+] Installing Tailscale VPN..."
	@[ -x scripts/install-tailscale.sh ] && scripts/install-tailscale.sh || { \
		echo "[!] scripts/install-tailscale.sh not found or not executable"; }

check-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "[ERROR] $(ENV_FILE) not found! Run 'make prepare-env' first."; \
		exit 1; \
	fi

check-tools:
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			echo "[ERROR] Required tool '$$tool' is not installed. Run scripts/setup-rpi.sh"; \
			exit 1; \
		fi; \
	done
	@echo "[+] All required tools present"

# -------- Mesh Installation (one-time) --------
mesh-install: check-env
	@echo "[+] Installing Nightwatch mesh service to $(INSTALL_DIR)..."
	@sudo mkdir -p $(INSTALL_DIR)/scripts
	@sudo cp $(MESH_SCRIPT) $(INSTALL_DIR)/scripts/mesh-fix.sh
	@sudo chmod +x $(INSTALL_DIR)/scripts/mesh-fix.sh
	@sudo cp $(ENV_FILE) $(INSTALL_DIR)/.env
	@sudo cp $(MESH_SERVICE) /etc/systemd/system/nightwatch-mesh.service
	@sudo systemctl daemon-reload
	@echo "[+] Installed. Run 'make mesh-setup' to enable and start."

# -------- Application Lifecycle (Docker Compose) --------
up: check-env
	@echo "[+] Starting application containers..."
	$(DC) --env-file $(ENV_FILE) up -d
	@echo "[+] Services started. Web interface at http://$$(grep MESH_IP $(ENV_FILE) | head -1 | cut -d= -f2)"

down: check-env
	@echo "[+] Stopping application containers..."
	$(DC) --env-file $(ENV_FILE) down

restart: down up

logs:
	@echo "[+] Following logs (Ctrl+C to stop)..."
	$(DC) logs -f

clean: down
	@echo "[+] Removing containers and volumes..."
	$(DC) --env-file $(ENV_FILE) down -v
	@docker system prune -f

# -------- Mesh Network Control (Host) --------
mesh-setup: check-tools
	@echo "[+] Setting up mesh network..."
	@if [ ! -f /etc/systemd/system/nightwatch-mesh.service ]; then \
		echo "[!] Service not installed. Running 'make mesh-install' first..."; \
		$(MAKE) mesh-install; \
	fi
	@sudo systemctl daemon-reload
	@sudo systemctl enable nightwatch-mesh.service
	@sudo systemctl start nightwatch-mesh.service
	@sleep 3
	@sudo systemctl --no-pager --full status nightwatch-mesh.service || true

mesh-reset: check-tools
	@echo "[+] Stopping mesh network..."
	@sudo systemctl stop nightwatch-mesh.service 2>/dev/null || true
	@echo "[+] Mesh network stopped"

mesh-status: check-tools
	@sudo $(MESH_SCRIPT) status 2>/dev/null || \
		sudo $(INSTALL_DIR)/scripts/mesh-fix.sh status 2>/dev/null || \
		echo "[!] Could not get mesh status"

mesh-test: check-tools
	@echo "[+] Testing mesh connectivity..."
	@echo ""
	@echo "== Local bat0 Interface =="
	@ip -4 addr show dev bat0 2>/dev/null | grep inet | awk '{print "  Local IP: " $$2}' || echo "  [!] bat0 not found"
	@echo ""
	@echo "== batman-adv Originators =="
	@batctl meshif bat0 o 2>/dev/null | head -10 || batctl o 2>/dev/null | head -10 || echo "  (none)"
	@echo ""
	@echo "== Ping Test =="
	@. ./$(ENV_FILE) 2>/dev/null; \
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
	@echo "== Docker Services =="
	@docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || echo "  (docker not running)"

# -------- Combined Operations --------
start: check-tools
	@echo "====================================="
	@echo "  Starting Nightwatch"
	@echo "====================================="
	@$(MAKE) mesh-setup
	@echo ""
	@echo "[+] Waiting for mesh to stabilize..."
	@sleep 3
	@$(MAKE) up
	@sleep 2
	@echo ""
	@$(MAKE) mesh-test

stop:
	@echo "[+] Stopping Nightwatch..."
	@$(MAKE) down 2>/dev/null || true
	@$(MAKE) mesh-reset 2>/dev/null || true
	@echo "[+] Nightwatch stopped"

full-restart: stop start

# -------- Monitoring --------
monitor: check-tools
	@while true; do \
		clear; \
		echo "=== NIGHTWATCH MONITOR === ($$(date)) Ctrl+C to exit"; \
		echo ""; \
		sudo $(MESH_SCRIPT) status 2>/dev/null || \
			sudo $(INSTALL_DIR)/scripts/mesh-fix.sh status 2>/dev/null || true; \
		echo ""; \
		echo "== Docker Services =="; \
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true; \
		sleep 5; \
	done

# -------- Testing --------
SHELL_SCRIPTS := scripts/mesh-fix.sh scripts/setup-rpi.sh scripts/test-docker.sh \
                 scripts/test-mesh.sh scripts/setup-distributed-irc.sh \
                 scripts/prepare-env.sh scripts/install-tailscale.sh \
                 scripts/firstboot.sh scripts/prepare-sdcard.sh \
                 scripts/build-image.sh scripts/nodeconfig.sh

test: test-go test-lint
	@echo ""
	@echo "====================================="
	@echo "  All tests passed"
	@echo "====================================="

test-go:
	@echo "== Go Unit Tests (irc-bridge) =="
	@cd irc-bridge-go && go test -v -count=1 -timeout 30s ./...
	@echo ""

test-lint:
	@echo "== Shell Script Lint (shellcheck) =="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_SCRIPTS); \
		echo "[+] All scripts pass shellcheck"; \
	else \
		echo "[!] shellcheck not installed — skipping (install: apt install shellcheck / brew install shellcheck)"; \
	fi
	@echo ""

test-docker:
	@echo "== Docker Integration Tests =="
	@scripts/test-docker.sh

test-mesh:
	@echo "== Mesh Integration Tests =="
	@sudo scripts/test-mesh.sh

test-mesh-quick:
	@echo "== Mesh Integration Tests (quick) =="
	@sudo scripts/test-mesh.sh --quick

# -------- SD Card Deployment --------
NODE ?= 0
GW ?= 0

sdcard:
	@if [ "$(NODE)" = "0" ]; then \
		echo "Usage: make sdcard NODE=<number> [GW=1]"; \
		echo "  NODE: Pi number (1-20)"; \
		echo "  GW:   Set to 1 for gateway node"; \
		echo ""; \
		echo "Example: make sdcard NODE=1"; \
		echo "         make sdcard NODE=3 GW=1"; \
		exit 1; \
	fi
	@if [ "$(GW)" = "1" ]; then \
		scripts/prepare-sdcard.sh $(NODE) --gateway; \
	else \
		scripts/prepare-sdcard.sh $(NODE); \
	fi

update:
	@echo "======================================"
	@echo "  Updating Nightwatch"
	@echo "======================================"
	@echo ""
	@echo "[1/4] Stopping services..."
	@$(MAKE) stop 2>/dev/null || true
	@echo ""
	@echo "[2/4] Syncing code to /opt/nightwatch..."
	@sudo rsync -a --delete \
		--exclude='.git' \
		--exclude='.env' \
		--exclude='ngircd/ngircd.conf' \
		--exclude='*.log' \
		--exclude='.DS_Store' \
		--exclude='.firstboot-done' \
		. /opt/nightwatch/
	@sudo chmod +x /opt/nightwatch/scripts/*.sh
	@echo "[+] Code synced (node config preserved)"
	@echo ""
	@echo "[3/4] Rebuilding Docker images..."
	@cd /opt/nightwatch && sudo docker compose --env-file .env build
	@echo ""
	@echo "[4/4] Restarting services..."
	@sudo systemctl daemon-reload
	@$(MAKE) start 2>/dev/null || sudo systemctl restart nightwatch-mesh.service
	@sudo systemctl restart nightwatch-docker.service 2>/dev/null || true
	@echo ""
	@echo "[+] Update complete. No reboot needed."

build-image:
	@echo "== Building Nightwatch Image =="
	@sudo scripts/build-image.sh

.DEFAULT_GOAL := help
