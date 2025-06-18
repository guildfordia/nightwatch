import logging
from typing import Optional, Dict, Any, Callable
from functools import wraps
import time
from datetime import datetime
import json

logger = logging.getLogger(__name__)

class MeshError(Exception):
    """Base exception for mesh network errors."""
    def __init__(self, message: str, node_id: Optional[str] = None, 
                 error_code: Optional[str] = None):
        self.message = message
        self.node_id = node_id
        self.error_code = error_code
        self.timestamp = datetime.now()
        super().__init__(self.message)

class NetworkError(MeshError):
    """Network-related errors."""
    pass

class ConfigurationError(MeshError):
    """Configuration-related errors."""
    pass

class NodeError(MeshError):
    """Node-specific errors."""
    pass

class ErrorHandler:
    """Handles errors and implements recovery strategies."""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.error_history: Dict[str, list] = {}
        self.recovery_attempts: Dict[str, int] = {}
        self.max_retries = config.get('error_handling', {}).get('max_retries', 3)
        self.retry_delay = config.get('error_handling', {}).get('retry_delay', 5)
        
    def handle_error(self, error: Exception, context: Optional[Dict] = None) -> bool:
        """Handle an error and attempt recovery."""
        error_id = self._generate_error_id(error)
        
        # Log error
        self._log_error(error, context)
        
        # Update error history
        self._update_error_history(error_id, error, context)
        
        # Check if we should attempt recovery
        if self._should_attempt_recovery(error_id):
            return self._attempt_recovery(error, context)
        
        return False

    def _generate_error_id(self, error: Exception) -> str:
        """Generate a unique ID for the error."""
        timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
        error_type = error.__class__.__name__
        return f"{error_type}_{timestamp}"

    def _log_error(self, error: Exception, context: Optional[Dict] = None):
        """Log error with context."""
        log_data = {
            'error': str(error),
            'type': error.__class__.__name__,
            'timestamp': datetime.now().isoformat(),
            'context': context or {}
        }
        
        if isinstance(error, MeshError):
            log_data.update({
                'node_id': error.node_id,
                'error_code': error.error_code
            })
        
        logger.error(json.dumps(log_data))

    def _update_error_history(self, error_id: str, error: Exception, 
                            context: Optional[Dict] = None):
        """Update error history with new error."""
        if error_id not in self.error_history:
            self.error_history[error_id] = []
        
        error_entry = {
            'timestamp': datetime.now().isoformat(),
            'error': str(error),
            'type': error.__class__.__name__,
            'context': context or {}
        }
        
        self.error_history[error_id].append(error_entry)

    def _should_attempt_recovery(self, error_id: str) -> bool:
        """Determine if recovery should be attempted."""
        if error_id not in self.recovery_attempts:
            self.recovery_attempts[error_id] = 0
        
        return self.recovery_attempts[error_id] < self.max_retries

    def _attempt_recovery(self, error: Exception, context: Optional[Dict] = None) -> bool:
        """Attempt to recover from the error."""
        error_id = self._generate_error_id(error)
        self.recovery_attempts[error_id] += 1
        
        try:
            if isinstance(error, NetworkError):
                return self._recover_network_error(error, context)
            elif isinstance(error, ConfigurationError):
                return self._recover_configuration_error(error, context)
            elif isinstance(error, NodeError):
                return self._recover_node_error(error, context)
            else:
                return self._recover_generic_error(error, context)
        except Exception as recovery_error:
            logger.error(f"Recovery attempt failed: {str(recovery_error)}")
            return False

    def _recover_network_error(self, error: NetworkError, 
                             context: Optional[Dict] = None) -> bool:
        """Attempt to recover from network errors."""
        # Implement network-specific recovery strategies
        time.sleep(self.retry_delay)
        return True

    def _recover_configuration_error(self, error: ConfigurationError, 
                                   context: Optional[Dict] = None) -> bool:
        """Attempt to recover from configuration errors."""
        # Implement configuration-specific recovery strategies
        time.sleep(self.retry_delay)
        return True

    def _recover_node_error(self, error: NodeError, 
                          context: Optional[Dict] = None) -> bool:
        """Attempt to recover from node-specific errors."""
        # Implement node-specific recovery strategies
        time.sleep(self.retry_delay)
        return True

    def _recover_generic_error(self, error: Exception, 
                             context: Optional[Dict] = None) -> bool:
        """Attempt to recover from generic errors."""
        time.sleep(self.retry_delay)
        return True

def error_handler(error_types: tuple = (Exception,)):
    """Decorator for handling errors in functions."""
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            try:
                return func(*args, **kwargs)
            except error_types as e:
                # Get error handler from instance if available
                handler = None
                if args and hasattr(args[0], 'error_handler'):
                    handler = args[0].error_handler
                
                if handler:
                    handler.handle_error(e, {
                        'function': func.__name__,
                        'args': str(args),
                        'kwargs': str(kwargs)
                    })
                raise
        return wrapper
    return decorator 