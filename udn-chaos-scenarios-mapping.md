# UDN Chaos Scenarios Mapping

## 🎯 Common Chaos → UDN-Specific Chaos Scenario Mapping

### **Node-Level Chaos Scenarios**

| Traditional Chaos | UDN Layer 2 Equivalent | UDN Layer 3 Equivalent |
|---|---|---|
| **Kill worker node** | Kill node + test L2 bridge failover | Kill node + test L3 routing reconvergence |
| **Network partition node** | Partition OVN bridge on node | Partition OVN router on node |
| **CPU pressure node** | CPU pressure → OVN bridge performance | CPU pressure → OVN router performance |
| **Memory pressure node** | Memory pressure → bridge table limits | Memory pressure → routing table limits |
| **Disk I/O pressure** | I/O pressure → OVN database writes | I/O pressure → flow table updates |

### **Network-Level Chaos Scenarios**

| Traditional Chaos | UDN Layer 2 Equivalent | UDN Layer 3 Equivalent |
|---|---|---|
| **Network partition** | UDN logical switch partition | UDN logical router partition |
| **Packet loss** | L2 broadcast storm simulation | L3 routing loop creation |
| **High latency** | Bridge forwarding delays | Router processing delays |
| **Bandwidth limit** | L2 flood limiting | L3 route flapping |
| **DNS failure** | Cross-UDN name resolution | Inter-UDN routing discovery |

### **Service-Level Chaos Scenarios**

| Traditional Chaos | UDN Layer 2 Equivalent | UDN Layer 3 Equivalent |
|---|---|---|
| **Pod failure** | Pod failure in isolated UDN | Pod failure affecting UDN routes |
| **Service disruption** | UDN internal service failure | Cross-UDN service failure |
| **Load balancer failure** | UDN L2 load balancing | UDN L3 ECMP failure |
| **Ingress failure** | UDN bridge connectivity loss | UDN router gateway failure |
| **Storage failure** | PV access via UDN failure | Cross-UDN storage access |

### **Control Plane Chaos Scenarios**

| Traditional Chaos | UDN Layer 2 Equivalent | UDN Layer 3 Equivalent |
|---|---|---|
| **API server failure** | Your tested: +3.0% latency | Your tested: +2.8% latency |
| **ETCD failure** | OVN Northbound DB failure | OVN Southbound DB corruption |
| **Controller failure** | OVN bridge controller crash | OVN router controller crash |
| **Scheduler failure** | UDN-aware pod scheduling failure | Cross-UDN scheduling conflicts |
| **CNI failure** | OVN bridge plugin failure | OVN router plugin failure |

## 🚨 UDN-Specific Advanced Chaos Scenarios

### **A. OVN Infrastructure Chaos**

```yaml
ovn_chaos_scenarios:
  northbound_db:
    - corruption_injection
    - connection_timeout
    - transaction_deadlock
    - schema_version_mismatch
    
  southbound_db:
    - flow_table_corruption
    - logical_switch_deletion
    - port_binding_corruption
    - chassis_registration_failure
    
  ovn_controller:
    - memory_leak_simulation
    - cpu_starvation
    - openflow_connection_loss
    - local_chassis_failure
```

### **B. UDN Network Topology Chaos**

```yaml
udn_topology_chaos:
  layer2_specific:
    - logical_switch_segmentation
    - bridge_table_overflow
    - broadcast_storm_injection
    - vlan_tag_corruption
    - mac_learning_table_flush
    
  layer3_specific:
    - routing_table_corruption
    - next_hop_unreachable
    - route_flapping_injection
    - subnet_overlap_creation
    - gateway_router_failure
```

### **C. Cross-UDN Communication Chaos**

```yaml
cross_udn_chaos:
  isolation_tests:
    - namespace_network_partition
    - cross_udn_firewall_injection
    - udn_gateway_failure
    - inter_udn_routing_blackhole
    
  performance_degradation:
    - cross_udn_bandwidth_limiting
    - inter_udn_latency_injection
    - udn_connection_pool_exhaustion
    - cross_namespace_dns_failure
```

### **D. Resource Competition Chaos**

```yaml
udn_resource_chaos:
  memory_pressure:
    - ovn_memory_starvation
    - flow_table_memory_exhaustion
    - logical_port_limit_breach
    - connection_tracking_overflow
    
  cpu_competition:
    - ovn_controller_cpu_starvation
    - openflow_processing_delays
    - bridge_forwarding_bottleneck
    - routing_calculation_timeout
```

## 📊 UDN Chaos Test Matrix

### **Based on Your Test Environment (AWS 9-node cluster)**

| Scenario Category | Layer 2 Priority | Layer 3 Priority | Expected Impact |
|---|---|---|---|
| **Node Failures** | High | High | Well tested (+3% latency) |
| **OVN DB Chaos** | Medium | High | Untested - critical |
| **Network Partition** | High | Medium | Bridge vs routing recovery |
| **Resource Pressure** | Medium | High | Layer 3 vulnerable (25% overhead) |
| **Cross-UDN Comm** | Low | High | Layer 3 routing complexity |

## 🎯 Recommended UDN Chaos Test Scenarios

### **Phase 1: Foundation (Start Here)**
```yaml
phase1_scenarios:
  - ovn_controller_restart
  - logical_switch_deletion_recovery
  - udn_namespace_isolation_test
  - cross_udn_connectivity_validation
```

### **Phase 2: Intermediate** 
```yaml
phase2_scenarios:
  - ovn_northbound_db_failure
  - bridge_forwarding_performance_chaos
  - udn_resource_starvation_test
  - inter_udn_routing_disruption
```

### **Phase 3: Advanced**
```yaml
phase3_scenarios:
  - ovn_database_split_brain
  - multi_udn_cascade_failure
  - udn_control_plane_chaos
  - cross_cluster_udn_partition
```

## 🔧 Implementation Templates

### **UDN Controller Chaos**
```bash
# Kill OVN controller on specific node
kubectl patch node NODE_NAME -p '{"spec":{"unschedulable":true}}'
systemctl stop ovn-controller
# Monitor UDN recovery
```

### **Logical Switch Chaos**
```bash
# Delete logical switch (Layer 2)
ovn-nbctl ls-del SWITCH_NAME
# Monitor bridge table recovery
```

### **Router Chaos**
```bash
# Corrupt routing table (Layer 3) 
ovn-nbctl lr-route-del ROUTER_NAME
# Monitor route reconvergence
```

## 📈 Expected Results vs Your Baseline

Based on your excellent master node chaos results:
- **Master Node**: +3.0% (L2) / +2.8% (L3) latency impact ✅ TESTED
- **OVN Infrastructure**: +10-20% latency impact (predicted)
- **Network Partition**: +15-30% latency impact (predicted)  
- **Resource Pressure**: +20-40% latency impact (predicted)

## 🚨 Monitoring Requirements for UDN Chaos

```yaml
udn_chaos_monitoring:
  ovn_metrics:
    - ovn_northbound_db_status
    - ovn_southbound_db_status
    - logical_switch_count
    - logical_router_count
    - port_binding_count
    
  network_metrics:
    - per_udn_latency
    - cross_udn_connectivity
    - ovn_controller_health
    - flow_table_utilization
    
  resource_metrics:
    - ovn_memory_usage
    - ovn_cpu_utilization  
    - connection_tracking_usage
    - flow_table_memory_usage
``` 