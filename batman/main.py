import logging
import sys
from typing import Dict, Any
from pathlib import Path
from config.validator import ConfigValidator, ConfigValidationError
from monitoring.mesh_monitor import MeshMonitor
from error.error_handler import ErrorHandler, error_handler

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('batman.log')
    ]
)

logger = logging.getLogger(__name__)

class Batman:
    """Main BATMAN component class."""
    
    def __init__(self, config_path: str = "config/config.yml"):
        self.config_path = Path(config_path)
        self.validator = ConfigValidator(config_path)
        self.error_handler = ErrorHandler({})
        self.monitor = None
        
    @error_handler((ConfigValidationError,))
    def validate_config(self) -> bool:
        """Validate configuration with error handling."""
        logger.info("Validating configuration...")
        return self.validator.validate() and \
               self.validator.validate_network_connectivity() and \
               self.validator.validate_mesh_topology()
    
    @error_handler((Exception,))
    def start_monitoring(self):
        """Start the mesh network monitoring."""
        logger.info("Starting mesh network monitoring...")
        self.monitor = MeshMonitor(self.validator.config)
        self.monitor.start()
    
    @error_handler((Exception,))
    def stop_monitoring(self):
        """Stop the mesh network monitoring."""
        if self.monitor:
            logger.info("Stopping mesh network monitoring...")
            self.monitor.stop()
    
    def start(self):
        """Start the BATMAN component."""
        try:
            # Validate configuration
            if not self.validate_config():
                logger.error("Configuration validation failed")
                return False
            
            # Start monitoring
            self.start_monitoring()
            
            logger.info("BATMAN component started successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to start BATMAN component: {str(e)}")
            self.error_handler.handle_error(e)
            return False
    
    def stop(self):
        """Stop the BATMAN component."""
        try:
            self.stop_monitoring()
            logger.info("BATMAN component stopped successfully")
        except Exception as e:
            logger.error(f"Error while stopping BATMAN component: {str(e)}")
            self.error_handler.handle_error(e)

def start():
    """Start the BATMAN component."""
    batman = Batman()
    return batman.start()

if __name__ == "__main__":
    start() 