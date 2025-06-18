import time
import logging
from typing import Dict, List, Optional
import psutil
import prometheus_client
from prometheus_client import Gauge, Counter, Histogram
import threading
from dataclasses import dataclass
from datetime import datetime

logger = logging.getLogger(__name__)

@dataclass
class NodeMetrics:
    """Metrics for a single mesh node."""
    node_id: str
    latency: float
    bandwidth: float
    packet_loss: float
    signal_strength: float
    last_seen: datetime
    status: str

class MeshMonitor:
    """Monitors mesh network health and performance."""
    
    def __init__(self, config: Dict):
        self.config = config
        self.metrics: Dict[str, NodeMetrics] = {}
        self.running = False
        self.monitor_thread: Optional[threading.Thread] = None
        
        # Prometheus metrics
        self.node_latency = Gauge('mesh_node_latency_seconds', 
                                'Latency to mesh node in seconds',
                                ['node_id'])
        self.node_bandwidth = Gauge('mesh_node_bandwidth_bytes',
                                  'Available bandwidth to node in bytes',
                                  ['node_id'])
        self.node_packet_loss = Gauge('mesh_node_packet_loss_ratio',
                                    'Packet loss ratio to node',
                                    ['node_id'])
        self.node_signal = Gauge('mesh_node_signal_strength_dbm',
                               'Signal strength to node in dBm',
                               ['node_id'])
        self.node_status = Gauge('mesh_node_status',
                               'Node status (1=up, 0=down)',
                               ['node_id'])
        self.mesh_errors = Counter('mesh_errors_total',
                                 'Total number of mesh network errors',
                                 ['error_type'])
        self.mesh_operations = Histogram('mesh_operation_duration_seconds',
                                       'Duration of mesh operations',
                                       ['operation'])

    def start(self):
        """Start the monitoring process."""
        if self.running:
            logger.warning("Monitor already running")
            return

        self.running = True
        self.monitor_thread = threading.Thread(target=self._monitor_loop)
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
        logger.info("Mesh monitor started")

    def stop(self):
        """Stop the monitoring process."""
        self.running = False
        if self.monitor_thread:
            self.monitor_thread.join(timeout=5)
        logger.info("Mesh monitor stopped")

    def _monitor_loop(self):
        """Main monitoring loop."""
        while self.running:
            try:
                self._update_metrics()
                time.sleep(self.config['monitoring']['interval'])
            except Exception as e:
                logger.error(f"Error in monitor loop: {str(e)}")
                self.mesh_errors.labels(error_type='monitor_loop').inc()
                time.sleep(5)  # Back off on error

    def _update_metrics(self):
        """Update metrics for all nodes."""
        with self.mesh_operations.labels(operation='update_metrics').time():
            for node in self.config['mesh']['nodes']:
                try:
                    metrics = self._collect_node_metrics(node)
                    self._update_prometheus_metrics(metrics)
                    self.metrics[node['id']] = metrics
                except Exception as e:
                    logger.error(f"Failed to update metrics for node {node['id']}: {str(e)}")
                    self.mesh_errors.labels(error_type='node_metrics').inc()

    def _collect_node_metrics(self, node: Dict) -> NodeMetrics:
        """Collect metrics for a single node."""
        try:
            # Simulate metric collection - replace with actual implementation
            latency = self._measure_latency(node['ip'])
            bandwidth = self._measure_bandwidth(node['ip'])
            packet_loss = self._measure_packet_loss(node['ip'])
            signal_strength = self._measure_signal_strength(node['ip'])
            
            return NodeMetrics(
                node_id=node['id'],
                latency=latency,
                bandwidth=bandwidth,
                packet_loss=packet_loss,
                signal_strength=signal_strength,
                last_seen=datetime.now(),
                status='up' if latency < 1.0 else 'down'
            )
        except Exception as e:
            logger.error(f"Failed to collect metrics for node {node['id']}: {str(e)}")
            raise

    def _update_prometheus_metrics(self, metrics: NodeMetrics):
        """Update Prometheus metrics for a node."""
        self.node_latency.labels(node_id=metrics.node_id).set(metrics.latency)
        self.node_bandwidth.labels(node_id=metrics.node_id).set(metrics.bandwidth)
        self.node_packet_loss.labels(node_id=metrics.node_id).set(metrics.packet_loss)
        self.node_signal.labels(node_id=metrics.node_id).set(metrics.signal_strength)
        self.node_status.labels(node_id=metrics.node_id).set(1 if metrics.status == 'up' else 0)

    def _measure_latency(self, ip: str) -> float:
        """Measure latency to a node."""
        # Implement actual latency measurement
        return 0.1  # Placeholder

    def _measure_bandwidth(self, ip: str) -> float:
        """Measure available bandwidth to a node."""
        # Implement actual bandwidth measurement
        return 1000000  # Placeholder

    def _measure_packet_loss(self, ip: str) -> float:
        """Measure packet loss to a node."""
        # Implement actual packet loss measurement
        return 0.0  # Placeholder

    def _measure_signal_strength(self, ip: str) -> float:
        """Measure signal strength to a node."""
        # Implement actual signal strength measurement
        return -60  # Placeholder

    def get_node_health(self, node_id: str) -> Dict:
        """Get health status for a specific node."""
        if node_id not in self.metrics:
            return {'status': 'unknown', 'last_seen': None}
        
        metrics = self.metrics[node_id]
        return {
            'status': metrics.status,
            'last_seen': metrics.last_seen.isoformat(),
            'latency': metrics.latency,
            'bandwidth': metrics.bandwidth,
            'packet_loss': metrics.packet_loss,
            'signal_strength': metrics.signal_strength
        }

    def get_mesh_health(self) -> Dict:
        """Get overall mesh network health."""
        total_nodes = len(self.config['mesh']['nodes'])
        up_nodes = sum(1 for m in self.metrics.values() if m.status == 'up')
        
        return {
            'total_nodes': total_nodes,
            'up_nodes': up_nodes,
            'health_ratio': up_nodes / total_nodes if total_nodes > 0 else 0,
            'nodes': {node_id: self.get_node_health(node_id) 
                     for node_id in self.metrics}
        } 