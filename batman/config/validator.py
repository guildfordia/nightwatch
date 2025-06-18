from typing import Dict, Any, Optional
import jsonschema
from jsonschema import validate
import yaml
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

class ConfigValidationError(Exception):
    """Custom exception for configuration validation errors."""
    pass

class ConfigValidator:
    """Validates BATMAN component configuration against a schema."""
    
    CONFIG_SCHEMA = {
        "type": "object",
        "required": ["network", "mesh", "monitoring"],
        "properties": {
            "network": {
                "type": "object",
                "required": ["interface", "ip_range", "port"],
                "properties": {
                    "interface": {"type": "string"},
                    "ip_range": {"type": "string", "pattern": r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$"},
                    "port": {"type": "integer", "minimum": 1024, "maximum": 65535}
                }
            },
            "mesh": {
                "type": "object",
                "required": ["nodes", "protocol"],
                "properties": {
                    "nodes": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["id", "ip"],
                            "properties": {
                                "id": {"type": "string"},
                                "ip": {"type": "string", "format": "ipv4"}
                            }
                        }
                    },
                    "protocol": {
                        "type": "string",
                        "enum": ["batman-adv", "olsr", "babel"]
                    }
                }
            },
            "monitoring": {
                "type": "object",
                "required": ["enabled", "interval"],
                "properties": {
                    "enabled": {"type": "boolean"},
                    "interval": {"type": "integer", "minimum": 1},
                    "metrics": {
                        "type": "array",
                        "items": {"type": "string"}
                    }
                }
            }
        }
    }

    def __init__(self, config_path: str):
        self.config_path = Path(config_path)
        self.config: Optional[Dict[str, Any]] = None

    def load_config(self) -> Dict[str, Any]:
        """Load and validate configuration from file."""
        try:
            with open(self.config_path, 'r') as f:
                self.config = yaml.safe_load(f)
            return self.config
        except (yaml.YAMLError, FileNotFoundError) as e:
            raise ConfigValidationError(f"Failed to load configuration: {str(e)}")

    def validate(self) -> bool:
        """Validate configuration against schema."""
        if not self.config:
            self.load_config()

        try:
            validate(instance=self.config, schema=self.CONFIG_SCHEMA)
            return True
        except jsonschema.exceptions.ValidationError as e:
            logger.error(f"Configuration validation failed: {str(e)}")
            raise ConfigValidationError(f"Invalid configuration: {str(e)}")

    def validate_network_connectivity(self) -> bool:
        """Validate network connectivity settings."""
        if not self.config:
            raise ConfigValidationError("Configuration not loaded")

        try:
            # Validate IP range
            ip_range = self.config['network']['ip_range']
            # Add IP range validation logic here
            
            # Validate interface exists
            interface = self.config['network']['interface']
            # Add interface validation logic here
            
            return True
        except KeyError as e:
            raise ConfigValidationError(f"Missing required network configuration: {str(e)}")

    def validate_mesh_topology(self) -> bool:
        """Validate mesh network topology."""
        if not self.config:
            raise ConfigValidationError("Configuration not loaded")

        try:
            nodes = self.config['mesh']['nodes']
            if len(nodes) < 2:
                raise ConfigValidationError("Mesh network must have at least 2 nodes")
            
            # Validate node connectivity
            for node in nodes:
                if not self._validate_node(node):
                    raise ConfigValidationError(f"Invalid node configuration: {node['id']}")
            
            return True
        except KeyError as e:
            raise ConfigValidationError(f"Missing required mesh configuration: {str(e)}")

    def _validate_node(self, node: Dict[str, Any]) -> bool:
        """Validate individual node configuration."""
        try:
            # Add node-specific validation logic here
            return True
        except Exception as e:
            logger.error(f"Node validation failed: {str(e)}")
            return False 