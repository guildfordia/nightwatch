# Nightwatch Makefile — host manages direct IP over IBSS, containers run apps

# -------- Config --------
ENV_FILE            := .env
ENV_EXAMPLE_FILE    := .env.example

# Prefer Docker Compose v2, fall back if needed
DC ?= docker compose
ifeq (, $(shell which docker-compose 2>/dev/null))
  # keep default "docker compose"
else
  DC := docker-compose
endif

# Tools required on host
REQUIRED_TOOLS = docker ip iw

# -------- Phonies --------
.PHONY: all help prepare-env setup-distributed-irc install-tailscale \
        check-env check-tools up down restart logs clean \
        mesh-setup mesh-reset mesh-status mesh-test \
        start stop full-restart

all: start

help:
	@echo "Nightwatch Makefile"
	@echo ""
	@echo "Host mesh: Direct IP over IBSS (managed by nightwatch-mesh.service)"
	@echo "Containers: IRC server, bridge, and web interface"
	@echo ""
	@echo "Environment Setup:"
	@echo "  prepare-env            Create $(ENV_FILE) from $(ENV_EXAMPLE_FILE)"
	@echo "  setup-distributed-irc  Generate linked ngircd config from .env"
	@echo "  install-tailscale      Install Tailscale (optional)"
	@echo ""
	@echo "Application Control:"
	@echo "  up                     Bring up app services (IRC, bridge, nginx)"
	@echo "  down                   Bring down app services"
	@echo "  restart                Restart app services"
	@echo "  logs                   Follow app logs"
	@echo "  clean                  Remove containers and volumes"
	@echo ""
	@echo "Mesh Network Control:"
	@echo "  mesh-setup             Enable & start host mesh service"
	@echo "  mesh-reset             Stop mesh service and clean up"
	@echo "  mesh-status            Show mesh network status"
	@echo "  mesh-test              Test connectivity to other nodes"
	@echo ""
	@echo "Combined Operations:"
	@echo "  start                  Start everything (mesh + apps)"
	@echo "  stop                   Stop everything (apps + mesh)"
	@echo "  full-restart           Complete restart"

# -------- Environment Setup --------
prepare-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "[+] Creating $(ENV_FILE) from $(ENV_EXAMPLE_FILE)..."; \
		cp $(ENV_EXAMPLE_FILE) $(ENV_FILE); \
		echo "[!] Please edit $(ENV_FILE) and set your node's MESH_IP"; \
	else \
		echo "[+] $(ENV_FILE) already exists."; \
	fi
	@[ -x scripts/prepare-env.sh ] && scripts/prepare-env.sh || true

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
			echo "[ERROR] Required tool '$$tool' is not installed."; \
			exit 1; \
		fi; \
	done
	@echo "[✓] All required tools are installed"

# -------- Application Lifecycle (Docker Compose) --------
up: check-env
	@echo "[+] Starting application containers..."
	$(DC) --env-file $(ENV_FILE) up -d
	@echo "[✓] Services started. Web interface at http://localhost:80"

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
	@echo "[+] Setting up mesh network on host..."
	@if [ ! -f /etc/systemd/system/nightwatch-mesh.service ]; then \
		echo "[!] nightwatch-mesh.service not found. Please install it first."; \
		exit 1; \
	fi
	@sudo systemctl daemon-reload
	@sudo systemctl enable nightwatch-mesh.service
	@sudo systemctl start nightwatch-mesh.service
	@sleep 2
	@sudo systemctl --no-pager --full status nightwatch-mesh.service || true

mesh-reset: check-tools
	@echo "[+] Stopping mesh network..."
	@sudo systemctl stop nightwatch-mesh.service 2>/dev/null || true
	@sudo iw dev wlan1 ibss leave 2>/dev/null || true
	@sudo ip addr flush dev wlan1 2>/dev/null || true
	@sudo ip link set wlan1 down 2>/dev/null || true
	@echo "[✓] Mesh network stopped"

mesh-status: check-tools
	@echo "[+] Mesh Network Status:"
	@echo ""
	@echo "== Interface Status =="
	@ip link show wlan1 2>/dev/null | grep -E "state|mtu" || echo "[!] wlan1 not found"
	@echo ""
	@echo "== IBSS Network =="
	@iw dev wlan1 info 2>/dev/null | grep -E "ssid|type|channel|freq" || echo "[!] Not in IBSS mode"
	@echo ""
	@echo "== IP Address =="
	@ip -4 addr show dev wlan1 2>/dev/null | grep inet || echo "[!] No IP assigned"
	@echo ""
	@echo "== IBSS Stations (Neighbors) =="
	@iw dev wlan1 station dump 2>/dev/null | grep -E "Station|signal|tx bytes|rx bytes" || echo "[!] No stations found"
	@echo ""
	@echo "== ARP Table =="
	@arp -n | grep wlan1 || echo "[!] No ARP entries"

mesh-test: check-tools
	@echo "[+] Testing mesh connectivity..."
	@echo ""
	@echo "== Local Interface =="
	@ip -4 addr show dev wlan1 | grep inet | awk '{print "Local IP: " $$2}'
	@echo ""
	@echo "== Reachability Test =="
	@for ip in 192.168.199.101 192.168.199.102 192.168.199.103; do \
		if ip -4 addr show | grep -q $$ip; then \
			echo "✓ $$ip (this node)"; \
		else \
			ping -c 1 -W 1 $$ip >/dev/null 2>&1 && \
			echo "✓ $$ip reachable ($(ping -c 1 -W 1 $$ip 2>/dev/null | grep 'time=' | cut -d'=' -f4))" || \
			echo "✗ $$ip unreachable"; \
		fi \
	done
	@echo ""
	@echo "== IRC Service Test =="
	@nc -zv localhost 80 2>&1 | grep -E "succeeded|open" && echo "✓ Web interface ready" || echo "✗ Web interface not responding"

# -------- Combined Operations --------
start: check-tools
	@echo "[+] Starting Nightwatch system..."
	@$(MAKE) mesh-setup
	@echo "[+] Waiting for mesh to stabilize..."
	@sleep 3
	@$(MAKE) up
	@sleep 2
	@$(MAKE) mesh-test

stop:
	@echo "[+] Stopping Nightwatch system..."
	@$(MAKE) down
	@$(MAKE) mesh-reset

full-restart: stop start

# -------- Monitoring --------
monitor: check-tools
	@while true; do \
		clear; \
		echo "=== NIGHTWATCH MONITOR === (Ctrl+C to exit)"; \
		echo ""; \
		$(MAKE) -s mesh-status; \
		echo ""; \
		echo "== Docker Services =="; \
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; \
		sleep 5; \
	done

.DEFAULT_GOAL := help
