#!/usr/bin/env python3
"""
Nightwatch BATMAN component entrypoint.

- Loads YAML config (via ConfigValidator)
- Applies safe environment overrides (MESH_IFACE, BATMON_PORT, MESH_IP_RANGE)
- Validates config & mesh connectivity
- Starts MeshMonitor with the effective config
- Writes logs to /var/log/nightwatch/batman.log

This file does **not** modify interfaces; that’s handled by your systemd
nightwatch-mesh.service. This process should only observe/monitor.
"""

import os
import sys
import logging
from pathlib import Path
from typing import Any, Dict, Optional

from config.validator import ConfigValidator, ConfigValidationError
from monitoring.mesh_monitor import MeshMonitor
from error.error_handler import ErrorHandler, error_handler


# ---------- Logging ----------
LOG_DIR = Path("/var/log/nightwatch")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "batman.log"),
    ],
)
logger = logging.getLogger("nightwatch.batman")


def _deep_get(d: Dict[str, Any], path: str) -> Optional[Any]:
    cur = d
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur


def _deep_set(d: Dict[str, Any], path: str, value: Any) -> None:
    parts = path.split(".")
    cur = d
    for p in parts[:-1]:
        if p not in cur or not isinstance(cur[p], dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = value


def _apply_overrides(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """
    Apply environment overrides to a loaded config dict.

    Recognized env vars:
      - MESH_IFACE / IFACE         -> network.interface
      - BATMON_PORT                -> network.port (int)
      - MESH_IP_RANGE              -> network.ip_range
    """
    iface = os.getenv("MESH_IFACE") or os.getenv("IFACE")
    if iface:
        _deep_set(cfg, "network.interface", iface)
        logger.info("Override: network.interface=%s", iface)

    port = os.getenv("BATMON_PORT")
    if port:
        try:
            port_i = int(port)
            _deep_set(cfg, "network.port", port_i)
            logger.info("Override: network.port=%d", port_i)
        except ValueError:
            logger.warning("Ignored invalid BATMON_PORT=%r (must be int)", port)

    ipr = os.getenv("MESH_IP_RANGE")
    if ipr:
        _deep_set(cfg, "network.ip_range", ipr)
        logger.info("Override: network.ip_range=%s", ipr)

    return cfg


class Batman:
    """Main BATMAN component class."""

    def __init__(self, config_path: str = "config/config.yml"):
        self.config_path = Path(config_path)
        self.validator = ConfigValidator(str(self.config_path))
        self.error_handler = ErrorHandler({})
        self.monitor: Optional[MeshMonitor] = None
        self._effective_config: Optional[Dict[str, Any]] = None

    def _load_and_override_config(self) -> bool:
        """
        Ask the validator to parse the config, then apply our env overrides.
        We do this BEFORE connectivity/topology checks so those use effective values.
        """
        # Many validators both parse & validate in one call; we first ensure it has loaded.
        # If ConfigValidator exposes a dedicated `load()` use that; otherwise call `validate()`
        # once to force parse, then we will run the other checks after overrides.
        ok = self.validator.validate()
        if not ok:
            logger.error("Base config file is invalid.")
            return False

        # Expect the validator to expose a `config` dict
        cfg = getattr(self.validator, "config", None)
        if not isinstance(cfg, dict):
            logger.error("Validator has no parsed config dict. Cannot continue.")
            return False

        self._effective_config = _apply_overrides(cfg)
        return True

    @error_handler((ConfigValidationError,))
    def validate_config(self) -> bool:
        """Validate configuration with error handling."""
        logger.info("Validating configuration...")

        # 1) Parse and apply overrides
        if not self._load_and_override_config():
            return False

        # 2) The following checks should use the *effective* config. If your
        #    ConfigValidator reads from self.config dynamically, we’re good.
        #    If it copies values internally, ensure it re-reads the dict or
        #    provide a setter (not shown here).
        ok_net = self.validator.validate_network_connectivity()
        ok_top = self.validator.validate_mesh_topology()

        if not (ok_net and ok_top):
            logger.error("Config validation failed (net_ok=%s, topo_ok=%s)", ok_net, ok_top)
            return False

        logger.info("Configuration validated successfully")
        return True

    @error_handler((Exception,))
    def start_monitoring(self):
        """Start the mesh network monitoring."""
        logger.info("Starting mesh network monitoring...")
        # MeshMonitor expects the effective config dict
        cfg = self._effective_config or getattr(self.validator, "config", {})
        self.monitor = MeshMonitor(cfg)
        self.monitor.start()
        logger.info("MeshMonitor started")

    @error_handler((Exception,))
    def stop_monitoring(self):
        """Stop the mesh network monitoring."""
        if self.monitor:
            logger.info("Stopping mesh network monitoring...")
            self.monitor.stop()
            logger.info("MeshMonitor stopped")

    def start(self) -> bool:
        """Start the BATMAN component."""
        try:
            if not self.validate_config():
                logger.error("Configuration validation failed; refusing to start monitor.")
                return False

            self.start_monitoring()
            logger.info("BATMAN component started successfully")
            return True

        except Exception as e:
            logger.exception("Failed to start BATMAN component: %s", e)
            self.error_handler.handle_error(e)
            return False

    def stop(self):
        """Stop the BATMAN component."""
        try:
            self.stop_monitoring()
            logger.info("BATMAN component stopped successfully")
        except Exception as e:
            logger.exception("Error while stopping BATMAN component: %s", e)
            self.error_handler.handle_error(e)


def start() -> bool:
    """Start the BATMAN component (module entrypoint)."""
    batman = Batman()
    return batman.start()


if __name__ == "__main__":
    # Exit with non-zero on failure so systemd can restart if configured
    success = start()
    sys.exit(0 if success else 1)
