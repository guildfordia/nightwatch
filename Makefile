# Makefile for Nightwatch Project (BATMAN + docker-compose)

# Config
ENV_FILE = .env
ENV_EXAMPLE_FILE = .env.example
DC = docker-compose
BATMAN_SCRIPTS = batman/scripts
BATMAN_SETUP_SCRIPT = $(BATMAN_SCRIPTS)/host-mesh-setup.sh
BATMAN_RESET_SCRIPT = $(BATMAN_SCRIPTS)/host-mesh-setup.sh # (Assume same for reset, or add your own)
BATMAN_RUN_SCRIPT = $(BATMAN_SCRIPTS)/run.sh
PREPARE_ENV_SCRIPT = scripts/prepare-env.sh

# Tools required
REQUIRED_TOOLS = docker docker-compose batctl ip fping

.PHONY: all help check-env check-tools up down restart logs batman-setup batman-reset batman-status start stop full-restart prepare-env

all: start

help:
	@echo "Nightwatch Makefile"
	@echo "Available targets:"
	@echo "  all            - Run everything (BATMAN setup + services)"
	@echo "  prepare-env    - Prepare .env from .env.example and run env setup script"
	@echo "  up             - Bring up all services via docker-compose"
	@echo "  down           - Bring down all services"
	@echo "  restart        - Restart all services"
	@echo "  logs           - Show logs for all services"
	@echo "  batman-setup   - Setup BATMAN mesh networking (from .env)"
	@echo "  batman-reset   - Reset BATMAN mesh networking"
	@echo "  batman-status  - Show BATMAN mesh status"
	@echo "  start          - Setup BATMAN and bring up services"
	@echo "  stop           - Bring down services and reset BATMAN"
	@echo "  full-restart   - Full system restart (BATMAN + services)"
	@echo "  check-env      - Check for .env file"
	@echo "  check-tools    - Check for required tools"

prepare-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "[+] Creating $(ENV_FILE) from $(ENV_EXAMPLE_FILE)..."; \
		cp $(ENV_EXAMPLE_FILE) $(ENV_FILE); \
	else \
		echo "[+] $(ENV_FILE) already exists."; \
	fi
	@chmod +x $(PREPARE_ENV_SCRIPT)
	@$(PREPARE_ENV_SCRIPT)

check-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "[ERROR] $(ENV_FILE) not found! Please create it (see .env.example)."; \
		exit 1; \
	fi

check-tools:
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			echo "[ERROR] Required tool '$$tool' is not installed."; \
			exit 1; \
		fi \
	done

up: check-env check-tools
	@echo "[+] Bringing up all services with docker-compose..."
	$(DC) --env-file $(ENV_FILE) up -d

down: check-env check-tools
	@echo "[+] Bringing down all services..."
	$(DC) --env-file $(ENV_FILE) down

restart: down up

logs:
	@echo "[+] Showing logs for all services..."
	$(DC) logs -f

batman-setup: check-env check-tools
	@echo "[+] Setting up BATMAN mesh networking..."
	@chmod +x $(BATMAN_SETUP_SCRIPT)
	@$(BATMAN_SETUP_SCRIPT)

batman-reset: check-env check-tools
	@echo "[+] Resetting BATMAN mesh networking..."
	@# Add your own reset logic or script here
	@echo "[!] No dedicated reset script found. Stopping BATMAN interface..."
	@sudo ip link set bat0 down 2>/dev/null || true
	@sudo ip link delete bat0 type batadv 2>/dev/null || true

batman-status: check-tools
	@echo "[+] Checking BATMAN mesh status..."
	@if ! command -v batctl >/dev/null; then \
		echo "[!] batctl not installed. Mesh networking will not work."; \
		exit 0; \
	fi
	@if ! ip link show bat0 >/dev/null 2>&1; then \
		echo "[!] bat0 not found. Mesh networking will not work."; \
		exit 0; \
	fi
	@echo "[+] bat0 IPs:"
	@ip -4 addr show dev bat0 | grep inet | awk '{print $$2}' || true
	@echo ""
	@echo "[+] Neighbors (batctl n):"
	@sudo batctl n || true
	@echo ""
	@echo "[+] Originators (batctl o):"
	@sudo batctl o || true
	@echo ""
	@echo "[+] Scanning mesh subnet for reachable peers..."
	@fping -a -q -r1 -g 192.168.199.10 192.168.199.254 2>/dev/null || echo "[!] No mesh nodes reachable"

start: batman-setup up

stop: down batman-reset

full-restart: stop start