#!/usr/bin/env python3
"""
UDN Capacity Planning Calculator
Based on Chaos UDN Service Unavailability Test Results

This calculator helps determine optimal cluster sizing and layer selection
incorporating the 25% memory overhead of Layer 3 vs Layer 2.
"""

import argparse
import json
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

@dataclass
class UDNLayerProfile:
    """Performance profile for UDN layers based on test results"""
    layer_name: str
    ovn_memory_mb: float
    ovn_cpu_percent: float
    p99_latency_sec: float
    chaos_latency_penalty_percent: float
    
    def memory_overhead_per_node(self, node_count: int) -> float:
        """Calculate total memory overhead across all nodes"""
        return self.ovn_memory_mb * node_count
    
    def cpu_overhead_per_node(self, node_count: int) -> float:
        """Calculate total CPU overhead across all nodes"""
        return self.ovn_cpu_percent * node_count
    
    def chaos_latency_impact(self) -> float:
        """Calculate expected latency during chaos events"""
        return self.p99_latency_sec * (1 + self.chaos_latency_penalty_percent / 100)

# Test results from Chaos UDN Service Unavailability analysis
LAYER2_PROFILE = UDNLayerProfile(
    layer_name="Layer2",
    ovn_memory_mb=93.1,
    ovn_cpu_percent=4.68,
    p99_latency_sec=57.6,
    chaos_latency_penalty_percent=3.0
)

LAYER3_PROFILE = UDNLayerProfile(
    layer_name="Layer3", 
    ovn_memory_mb=116.0,
    ovn_cpu_percent=4.44,
    p99_latency_sec=60.4,
    chaos_latency_penalty_percent=2.8
)

@dataclass
class ClusterConfiguration:
    """Cluster configuration for capacity planning"""
    master_nodes: int
    worker_nodes: int
    infra_nodes: int
    master_memory_gb: float
    worker_memory_gb: float
    infra_memory_gb: float
    master_cpu_cores: float
    worker_cpu_cores: float
    infra_cpu_cores: float

@dataclass
class CapacityAnalysis:
    """Results of capacity analysis"""
    layer: str
    total_memory_overhead_gb: float
    total_cpu_overhead_percent: float
    memory_utilization_percent: float
    cpu_utilization_percent: float
    baseline_latency_ms: float
    chaos_latency_ms: float
    cost_score: float
    recommendation: str

class UDNCapacityPlanner:
    """Main capacity planning calculator"""
    
    def __init__(self, memory_cost_per_gb: float = 1.0, cpu_cost_per_core: float = 1.0):
        self.memory_cost_per_gb = memory_cost_per_gb
        self.cpu_cost_per_core = cpu_cost_per_core
        
    def analyze_layer_capacity(self, cluster: ClusterConfiguration, layer: UDNLayerProfile) -> CapacityAnalysis:
        """Analyze capacity requirements for a specific UDN layer"""
        
        # Calculate total cluster resources
        total_nodes = cluster.master_nodes + cluster.worker_nodes + cluster.infra_nodes
        total_memory_gb = (
            cluster.master_nodes * cluster.master_memory_gb +
            cluster.worker_nodes * cluster.worker_memory_gb +
            cluster.infra_nodes * cluster.infra_memory_gb
        )
        total_cpu_cores = (
            cluster.master_nodes * cluster.master_cpu_cores +
            cluster.worker_nodes * cluster.worker_cpu_cores +
            cluster.infra_nodes * cluster.infra_cpu_cores
        )
        
        # Calculate OVN overhead
        ovn_memory_overhead_gb = layer.memory_overhead_per_node(total_nodes) / 1024
        ovn_cpu_overhead_percent = layer.cpu_overhead_per_node(total_nodes)
        
        # Calculate utilization percentages
        memory_utilization = (ovn_memory_overhead_gb / total_memory_gb) * 100
        cpu_utilization = ovn_cpu_overhead_percent / total_cpu_cores
        
        # Calculate costs
        memory_cost = ovn_memory_overhead_gb * self.memory_cost_per_gb
        cpu_cost = (ovn_cpu_overhead_percent / 100) * self.cpu_cost_per_core
        total_cost = memory_cost + cpu_cost
        
        # Latency calculations (convert to ms)
        baseline_latency_ms = layer.p99_latency_sec * 1000
        chaos_latency_ms = layer.chaos_latency_impact() * 1000
        
        return CapacityAnalysis(
            layer=layer.layer_name,
            total_memory_overhead_gb=ovn_memory_overhead_gb,
            total_cpu_overhead_percent=ovn_cpu_overhead_percent,
            memory_utilization_percent=memory_utilization,
            cpu_utilization_percent=cpu_utilization,
            baseline_latency_ms=baseline_latency_ms,
            chaos_latency_ms=chaos_latency_ms,
            cost_score=total_cost,
            recommendation=""  # Will be filled by comparison
        )
    
    def compare_layers(self, cluster: ClusterConfiguration) -> Tuple[CapacityAnalysis, CapacityAnalysis, str]:
        """Compare Layer 2 vs Layer 3 for given cluster configuration"""
        
        layer2_analysis = self.analyze_layer_capacity(cluster, LAYER2_PROFILE)
        layer3_analysis = self.analyze_layer_capacity(cluster, LAYER3_PROFILE)
        
        # Determine recommendation based on multiple factors
        recommendation = self._determine_recommendation(layer2_analysis, layer3_analysis)
        
        layer2_analysis.recommendation = "Recommended" if "Layer 2" in recommendation else "Alternative"
        layer3_analysis.recommendation = "Recommended" if "Layer 3" in recommendation else "Alternative"
        
        return layer2_analysis, layer3_analysis, recommendation
    
    def _determine_recommendation(self, layer2: CapacityAnalysis, layer3: CapacityAnalysis) -> str:
        """Determine optimal layer based on analysis"""
        
        reasons = []
        
        # Memory efficiency comparison
        memory_savings_gb = layer3.total_memory_overhead_gb - layer2.total_memory_overhead_gb
        memory_savings_percent = (memory_savings_gb / layer3.total_memory_overhead_gb) * 100
        
        # CPU efficiency comparison  
        cpu_savings_percent = layer2.total_cpu_overhead_percent - layer3.total_cpu_overhead_percent
        cpu_savings_ratio = (cpu_savings_percent / layer2.total_cpu_overhead_percent) * 100
        
        # Latency comparison
        latency_difference_ms = layer3.baseline_latency_ms - layer2.baseline_latency_ms
        
        # Cost comparison
        cost_difference = layer3.cost_score - layer2.cost_score
        
        # Decision logic
        if layer2.memory_utilization_percent > 80:
            reasons.append("High memory pressure - Layer 2 memory savings critical")
            return f"Layer 2 Recommended: {'; '.join(reasons)}"
            
        if layer2.cpu_utilization_percent > 80:
            reasons.append("High CPU pressure - Layer 3 CPU savings beneficial")
            return f"Layer 3 Recommended: {'; '.join(reasons)}"
            
        if cost_difference < 0:
            reasons.append(f"Layer 3 is ${abs(cost_difference):.2f} more cost-effective")
            
        if memory_savings_percent > 15:
            reasons.append(f"Layer 2 saves {memory_savings_percent:.1f}% memory ({memory_savings_gb:.1f}GB)")
            
        if latency_difference_ms > 2000:  # 2 second difference threshold
            reasons.append(f"Layer 2 has {latency_difference_ms:.0f}ms better baseline latency")
            
        # Default recommendation logic
        if len(reasons) == 0 or cost_difference > 0:
            reasons.append("Better balance of performance and resource efficiency")
            return f"Layer 2 Recommended: {'; '.join(reasons)}"
        else:
            return f"Layer 3 Recommended: {'; '.join(reasons)}"

    def generate_scaling_analysis(self, base_cluster: ClusterConfiguration, scale_factors: List[int]) -> Dict:
        """Generate scaling analysis for different cluster sizes"""
        
        scaling_results = {}
        
        for scale_factor in scale_factors:
            scaled_cluster = ClusterConfiguration(
                master_nodes=base_cluster.master_nodes * scale_factor,
                worker_nodes=base_cluster.worker_nodes * scale_factor,
                infra_nodes=base_cluster.infra_nodes * scale_factor,
                master_memory_gb=base_cluster.master_memory_gb,
                worker_memory_gb=base_cluster.worker_memory_gb,
                infra_memory_gb=base_cluster.infra_memory_gb,
                master_cpu_cores=base_cluster.master_cpu_cores,
                worker_cpu_cores=base_cluster.worker_cpu_cores,
                infra_cpu_cores=base_cluster.infra_cpu_cores
            )
            
            layer2_analysis, layer3_analysis, recommendation = self.compare_layers(scaled_cluster)
            
            total_nodes = scaled_cluster.master_nodes + scaled_cluster.worker_nodes + scaled_cluster.infra_nodes
            scaling_results[f"{total_nodes}_nodes"] = {
                "cluster_config": scaled_cluster,
                "layer2_analysis": layer2_analysis,
                "layer3_analysis": layer3_analysis,
                "recommendation": recommendation
            }
            
        return scaling_results

def print_analysis_report(layer2: CapacityAnalysis, layer3: CapacityAnalysis, recommendation: str):
    """Print formatted capacity analysis report"""
    
    print("=" * 80)
    print("UDN CAPACITY PLANNING ANALYSIS")
    print("=" * 80)
    
    print(f"\n{'Metric':<30} {'Layer 2':<15} {'Layer 3':<15} {'Difference':<15}")
    print("-" * 80)
    
    # Memory comparison
    memory_diff = layer3.total_memory_overhead_gb - layer2.total_memory_overhead_gb
    memory_percent = (memory_diff / layer2.total_memory_overhead_gb) * 100
    print(f"{'Memory Overhead (GB)':<30} {layer2.total_memory_overhead_gb:<15.2f} {layer3.total_memory_overhead_gb:<15.2f} {memory_diff:+.2f} ({memory_percent:+.1f}%)")
    
    # CPU comparison
    cpu_diff = layer3.total_cpu_overhead_percent - layer2.total_cpu_overhead_percent
    cpu_percent = (cpu_diff / layer2.total_cpu_overhead_percent) * 100
    print(f"{'CPU Overhead (%)':<30} {layer2.total_cpu_overhead_percent:<15.2f} {layer3.total_cpu_overhead_percent:<15.2f} {cpu_diff:+.2f} ({cpu_percent:+.1f}%)")
    
    # Latency comparison
    latency_diff = layer3.baseline_latency_ms - layer2.baseline_latency_ms
    latency_percent = (latency_diff / layer2.baseline_latency_ms) * 100
    print(f"{'Baseline Latency (ms)':<30} {layer2.baseline_latency_ms:<15.0f} {layer3.baseline_latency_ms:<15.0f} {latency_diff:+.0f} ({latency_percent:+.1f}%)")
    
    # Chaos latency comparison
    chaos_diff = layer3.chaos_latency_ms - layer2.chaos_latency_ms
    print(f"{'Chaos Latency (ms)':<30} {layer2.chaos_latency_ms:<15.0f} {layer3.chaos_latency_ms:<15.0f} {chaos_diff:+.0f}")
    
    # Cost comparison
    cost_diff = layer3.cost_score - layer2.cost_score
    cost_percent = (cost_diff / layer2.cost_score) * 100 if layer2.cost_score > 0 else 0
    print(f"{'Cost Score':<30} {layer2.cost_score:<15.2f} {layer3.cost_score:<15.2f} {cost_diff:+.2f} ({cost_percent:+.1f}%)")
    
    print("\n" + "=" * 80)
    print("RECOMMENDATION")
    print("=" * 80)
    print(f"{recommendation}")
    
    print("\n" + "=" * 80)
    print("CHAOS RESILIENCE SUMMARY")
    print("=" * 80)
    print("Both layers show excellent chaos resilience:")
    print(f"• Layer 2: +3.0% latency impact during master failures")
    print(f"• Layer 3: +2.8% latency impact during master failures") 
    print(f"• Memory usage improves during chaos events")
    print(f"• CPU usage remains stable or improves during chaos")

def main():
    parser = argparse.ArgumentParser(description="UDN Capacity Planning Calculator")
    parser.add_argument("--master-nodes", type=int, default=3, help="Number of master nodes")
    parser.add_argument("--worker-nodes", type=int, default=3, help="Number of worker nodes")
    parser.add_argument("--infra-nodes", type=int, default=3, help="Number of infra nodes")
    parser.add_argument("--master-memory", type=float, default=16, help="Memory per master node (GB)")
    parser.add_argument("--worker-memory", type=float, default=16, help="Memory per worker node (GB)")
    parser.add_argument("--infra-memory", type=float, default=32, help="Memory per infra node (GB)")
    parser.add_argument("--master-cpu", type=float, default=4, help="CPU cores per master node")
    parser.add_argument("--worker-cpu", type=float, default=4, help="CPU cores per worker node")
    parser.add_argument("--infra-cpu", type=float, default=4, help="CPU cores per infra node")
    parser.add_argument("--memory-cost", type=float, default=1.0, help="Cost per GB memory")
    parser.add_argument("--cpu-cost", type=float, default=1.0, help="Cost per CPU core")
    parser.add_argument("--scaling-analysis", action="store_true", help="Generate scaling analysis")
    
    args = parser.parse_args()
    
    # Create cluster configuration
    cluster = ClusterConfiguration(
        master_nodes=args.master_nodes,
        worker_nodes=args.worker_nodes,
        infra_nodes=args.infra_nodes,
        master_memory_gb=args.master_memory,
        worker_memory_gb=args.worker_memory,
        infra_memory_gb=args.infra_memory,
        master_cpu_cores=args.master_cpu,
        worker_cpu_cores=args.worker_cpu,
        infra_cpu_cores=args.infra_cpu
    )
    
    # Create capacity planner
    planner = UDNCapacityPlanner(
        memory_cost_per_gb=args.memory_cost,
        cpu_cost_per_core=args.cpu_cost
    )
    
    # Perform analysis
    layer2_analysis, layer3_analysis, recommendation = planner.compare_layers(cluster)
    
    # Print results
    print_analysis_report(layer2_analysis, layer3_analysis, recommendation)
    
    # Optional scaling analysis
    if args.scaling_analysis:
        print("\n" + "=" * 80)
        print("SCALING ANALYSIS")
        print("=" * 80)
        
        scale_factors = [1, 2, 4, 8, 16]
        scaling_results = planner.generate_scaling_analysis(cluster, scale_factors)
        
        for scale_key, result in scaling_results.items():
            nodes = scale_key.replace("_nodes", "")
            l2_mem = result["layer2_analysis"].total_memory_overhead_gb
            l3_mem = result["layer3_analysis"].total_memory_overhead_gb
            mem_diff = l3_mem - l2_mem
            
            print(f"\n{nodes:>3} nodes: L2={l2_mem:6.1f}GB, L3={l3_mem:6.1f}GB, Diff={mem_diff:+6.1f}GB")

if __name__ == "__main__":
    main() 