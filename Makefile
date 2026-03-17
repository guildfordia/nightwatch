# Nightwatch — mesh network + chat on Raspberry Pi

ENV_FILE := .env

.PHONY: install run stop test scan update status logs sdlogs clean monitor blink image sdcard info router build-bridge help
.DEFAULT_GOAL := help

help:
	@echo "Nightwatch — mesh chat on Raspberry Pi"
	@echo ""
	@echo "  make install   First-time setup (run once per Pi)"
	@echo "  make run       Start mesh + apps"
	@echo "  make stop      Stop everything"
	@echo "  make test      Run all tests (mesh, services, load)"
	@echo "  make update    Pull latest code + restart"
	@echo "  make status    Show mesh & service status"
	@echo "  make logs      Follow service logs"
	@echo "  make clean     Stop services and clean state"
	@echo "  make monitor   Live dashboard (refreshes every 5s)"
	@echo "  make blink     Blink onboard LED to identify this Pi"
	@echo "  make info      Show detailed node info"
	@echo "  make scan      Advanced mesh network scan (all nodes)"
	@echo ""
	@echo "  make router       Configure GL.iNet router"
	@echo "  make image        Prepare Pi for SD card cloning"
	@echo "  make sdcard SD=X [NODE=N]  Prepare SD card (auto-picks node if omitted)"
	@echo "  make build-bridge Cross-compile irc-bridge (laptop)"
	@echo ""
	@echo "First time:  make install && make run && make test"

install:
	@sudo scripts/setup-rpi.sh $(ARGS)

run:
	@chmod +x scripts/*.sh 2>/dev/null || true
	@if [ ! -f /etc/systemd/system/nightwatch-mesh.service ]; then \
		echo "[!] Not installed yet. Run 'make install' first."; exit 1; fi
	@echo "[+] Starting mesh network..."
	@sudo systemctl daemon-reload
	@sudo systemctl enable nightwatch-mesh.service 2>/dev/null || true
	@sudo systemctl start nightwatch-mesh.service
	@sleep 3
	@sudo systemctl --no-pager --full status nightwatch-mesh.service || true
	@echo ""
	@echo "[+] Starting node discovery..."
	@sudo systemctl start nightwatch-discovery.service 2>/dev/null || true
	@echo ""
	@sudo chown -R $$(id -u):$$(id -g) ngircd/ 2>/dev/null || true
	@scripts/setup-distributed-irc.sh
	@echo ""
	@echo "[+] Starting app services..."
	@sudo systemctl start nightwatch-app.service
	@echo "[+] Waiting for services to be ready..."
	@for attempt in $$(seq 1 24); do \
		ALL_READY=true; \
		for svc in ngircd nightwatch-bridge nginx; do \
			if ! systemctl is-active --quiet "$$svc" 2>/dev/null; then ALL_READY=false; break; fi; \
		done; \
		if [ "$$ALL_READY" = true ]; then break; fi; \
		if [ "$$attempt" -eq 24 ]; then echo "  [!] Timed out waiting for services (proceeding anyway)"; break; fi; \
		sleep 5; \
	done
	@echo ""
	@echo "[+] Quick connectivity check..."
	@. ./$(ENV_FILE) 2>/dev/null; LOCAL=$${MESH_IP%/*}; \
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
	@echo "Services:"
	@for svc in ngircd nightwatch-bridge nginx; do \
		state=$$(systemctl is-active "$$svc" 2>/dev/null || echo "inactive"); \
		printf "  %-20s %s\n" "$$svc:" "$$state"; \
	done
	@echo ""
	@echo "[+] Nightwatch is running"

stop:
	@echo "[+] Stopping Nightwatch..."
	@sudo systemctl stop nightwatch-app.service 2>/dev/null || true
	@sudo systemctl stop nightwatch-discovery.service 2>/dev/null || true
	@sudo systemctl stop nightwatch-mesh.service 2>/dev/null || true
	@echo "[+] Nightwatch stopped"

test:
	@echo "====================================="
	@echo "  Nightwatch — Test Suite"
	@echo "====================================="
	@echo ""
	@sudo scripts/test-mesh.sh
	@echo ""
	@scripts/test-services.sh
	@echo ""
	@scripts/test-load.sh $(or $(CLIENTS),5) $(or $(MSGS),3)

update:
	@echo "[1/3] Pulling latest code..."
	@if git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then \
		if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then \
			echo "  [*] Stashing uncommitted changes..."; \
			git stash --include-untracked; \
		fi; \
		git pull; \
		if git stash list 2>/dev/null | grep -q .; then \
			echo "  [*] Restoring stashed changes..."; \
			git stash pop || echo "  [!] Stash pop had conflicts — resolve manually with 'git stash show -p'"; \
		fi; \
	else \
		echo "  [!] Remote unreachable — using code on disk"; \
	fi
	@chmod +x scripts/*.sh 2>/dev/null || true
	@echo "[2/3] Stopping services..."
	@sudo systemctl stop nightwatch-app.service 2>/dev/null || true
	@echo "[3/3] Restarting..."
	@$(MAKE) run
	@echo "[+] Update complete."

status:
	@sudo scripts/mesh-fix.sh status 2>/dev/null || echo "[!] Mesh status unavailable"
	@echo ""
	@echo "== App Services =="
	@for svc in ngircd nightwatch-bridge nginx; do \
		state=$$(systemctl is-active "$$svc" 2>/dev/null || echo "inactive"); \
		printf "  %-20s %s\n" "$$svc:" "$$state"; \
	done

logs:
	@sudo journalctl -u ngircd -u nightwatch-bridge -u nginx -f

sdlogs:
	@if [ -z "$(SD)" ]; then echo "Usage: make sdlogs SD=/dev/diskX"; exit 1; fi
	@PART="$(SD)s2"; \
	DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs; \
	if [ ! -x "$$DEBUGFS" ]; then echo "Run: brew install e2fsprogs"; exit 1; fi; \
	echo "=== /var/log/nightwatch-firstboot.log ==="; \
	sudo $$DEBUGFS -R "cat /var/log/nightwatch-firstboot.log" $$PART 2>/dev/null; \
	echo ""; \
	echo "=== /opt/nightwatch/.firstboot-done (stamp) ==="; \
	sudo $$DEBUGFS -R "cat /opt/nightwatch/.firstboot-done" $$PART 2>/dev/null || true

clean:
	@sudo systemctl stop nightwatch-app.service 2>/dev/null || true
	@sudo systemctl stop nightwatch-discovery.service 2>/dev/null || true
	@sudo systemctl stop nightwatch-mesh.service 2>/dev/null || true
	@echo "[+] All services stopped"

blink:
	@echo "Blinking LED for 10 seconds..."
	@sudo sh -c 'LED=/sys/class/leds/ACT; \
		if [ ! -d "$$LED" ]; then LED=/sys/class/leds/led0; fi; \
		if [ ! -d "$$LED" ]; then echo "No LED found"; exit 1; fi; \
		ORIG=$$(cat "$$LED/trigger" | grep -oP "\[\K[^\]]+"); \
		echo none > "$$LED/trigger"; \
		for i in $$(seq 1 20); do \
			echo 1 > "$$LED/brightness"; sleep 0.25; \
			echo 0 > "$$LED/brightness"; sleep 0.25; \
		done; \
		echo "$$ORIG" > "$$LED/trigger"'

monitor:
	@while true; do \
		clear; \
		echo "=== NIGHTWATCH MONITOR === ($$(date))  Ctrl+C to exit"; echo ""; \
		sudo scripts/mesh-fix.sh status 2>/dev/null || true; echo ""; \
		echo "== Services =="; \
		for svc in ngircd nightwatch-bridge nginx; do \
			state=$$(systemctl is-active "$$svc" 2>/dev/null || echo "inactive"); \
			printf "  %-20s %s\n" "$$svc:" "$$state"; \
		done; \
		sleep 5; \
	done

image:
	@sudo scripts/build-image.sh

router:
	@sudo scripts/setup-router.sh

build-bridge:
	@if ! command -v go >/dev/null 2>&1; then echo "Error: Go not installed"; exit 1; fi
	cd irc-bridge-go && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o irc-bridge .
	@echo "[+] Built irc-bridge-go/irc-bridge ($$(ls -lh irc-bridge-go/irc-bridge | awk '{print $$5}'))"

sdcard:
	@if [ -z "$(SD)" ]; then \
		echo "Usage: make sdcard SD=/dev/sdX [NODE=N] [MODE=mesh|gateway|sound-bridge]"; exit 1; fi
	@if command -v go >/dev/null 2>&1; then \
		echo "[+] Cross-compiling irc-bridge..."; \
		cd irc-bridge-go && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o irc-bridge .; \
	fi
	@NODE=$(NODE) scripts/prepare-sdcard.sh $(SD) $(if $(NODE),--node $(NODE),) $(if $(MODE),--mode $(MODE),) $(if $(filter true,$(GATEWAY)),--gateway,)

info:
	@scripts/nightwatch-info.sh

scan:
	@sudo scripts/test-scan.sh $(ARGS)
