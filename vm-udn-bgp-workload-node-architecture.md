# VM-UDN-BGP Integration with Workload Baremetal Node Architecture

## 🏗️ **Workload Baremetal Node Topology**

### **Key Architectural Requirements**
```
┌─────────────────────────────────────────────────────────────────┐
│                    SCALE/PERFORMANCE LAB                       │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ Bastion Host    │  │ OpenShift       │  │ WORKLOAD        │ │
│  │ (Deployment)    │  │ Cluster         │  │ BAREMETAL NODE  │ │
│  │                 │  │                 │  │                 │ │
│  │ • NOT FRR       │  │ • Masters (3)   │  │ • External FRR  │ │
│  │ • NOT Gateway   │  │ • Workers (N)   │  │ • kube-burner   │ │
│  │ • Deployment    │  │ • Infra (3)     │  │ • Dedicated     │ │
│  │   Only          │  │ • OVN-K8s BGP   │  │ • Same Lab      │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│           │                     │                     │         │
│           └─────────────────────┼─────────────────────┘         │
│                  Lab Network (L2 Segment)                      │
└─────────────────────────────────────────────────────────────────┘
```

### **Workload Baremetal Node Specifications**
```yaml
# Dedicated node requirements
Node Role: "workload-baremetal"
Purpose: 
  - External FRR Container (ASN 64512)
  - kube-burner Performance Testing
  - BGP Route Processing
  - VM Traffic Validation

Network Requirements:
  - Same L2 segment as OpenShift cluster
  - BGP peering capability with cluster nodes
  - External network access for performance testing
  - NOT the default gateway/bastion host

Resource Requirements:
  - CPU: 8+ cores (FRR + kube-burner)
  - Memory: 16+ GB (BGP tables + test workloads)
  - Storage: 100+ GB (logs + test artifacts)
  - Network: 10Gbps+ (performance testing)
```

## 🔄 **Updated Data Flow Architecture**

### **VM → External Traffic Path**
```
VM (192.168.100.10) on OpenShift Cluster
    ↓ L2 CUDN Bridge
UDN Network (192.168.100.0/24)
    ↓ OVN Logical Switch
OVN-K8s BGP Controller
    ↓ BGP Advertisement
OpenShift Cluster Nodes (198.18.0.1-3)
    ↓ BGP Session
┌─────────────────────────────────────────────────────────────┐
│            WORKLOAD BAREMETAL NODE (198.18.0.155)          │
│                                                             │
│  External FRR Container ←→ kube-burner Testing              │
│  • Receives BGP routes      • Validates connectivity       │
│  • Redistributes to lab     • Measures performance         │
│  • ASN 64512                • Generates test traffic       │
└─────────────────────────────────────────────────────────────┘
    ↓ Route Redistribution
Lab External Network Infrastructure
    ↓ Performance Testing & Direct Routing
External Performance Testing Targets
```

### **BGP Session Topology**
```
OpenShift Masters (BGP Speakers)
    ↓ eBGP Session (ASN 64513 → ASN 64512)
Workload Baremetal Node (198.18.0.155)
    ├─ External FRR Container (Route Processing)
    └─ kube-burner (Connectivity Validation)
```

## 🔧 **Workload Node Configuration**

### **A. External FRR Container on Workload Node**
```yaml
# External FRR deployment on workload baremetal
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-frr-workload
  namespace: workload-frr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: external-frr-workload
  template:
    metadata:
      labels:
        app: external-frr-workload
    spec:
      # Pin to workload baremetal node
      nodeSelector:
        node-role.kubernetes.io/workload-baremetal: ""
      hostNetwork: true  # Direct network access
      containers:
      - name: frr
        image: quay.io/frrouting/frr:latest
        securityContext:
          privileged: true
        env:
        - name: WORKLOAD_NODE_IP
          value: "198.18.0.155"
        - name: CLUSTER_BGP_PEERS
          value: "198.18.0.1,198.18.0.2,198.18.0.3"  # Master nodes
        volumeMounts:
        - name: frr-config
          mountPath: /etc/frr
      volumes:
      - name: frr-config
        configMap:
          name: workload-frr-config
```

### **B. FRR Configuration for Workload Node**
```bash
# /etc/frr/frr.conf on workload baremetal node
frr version 8.4
frr defaults traditional
hostname workload-frr-external
service integrated-vtysh-config

# BGP Configuration for VM route processing
router bgp 64512
 bgp router-id 198.18.0.155
 bgp log-neighbor-changes
 
 # BGP sessions with OpenShift cluster masters
 neighbor 198.18.0.1 remote-as 64513
 neighbor 198.18.0.1 description "OCP Master 1"
 neighbor 198.18.0.1 timers 3 9
 
 neighbor 198.18.0.2 remote-as 64513  
 neighbor 198.18.0.2 description "OCP Master 2"
 neighbor 198.18.0.2 timers 3 9
 
 neighbor 198.18.0.3 remote-as 64513
 neighbor 198.18.0.3 description "OCP Master 3" 
 neighbor 198.18.0.3 timers 3 9

 # Address family for VM subnets
 address-family ipv4 unicast
  # Accept VM subnet advertisements from cluster
  neighbor 198.18.0.1 route-map vm-routes-in in
  neighbor 198.18.0.2 route-map vm-routes-in in
  neighbor 198.18.0.3 route-map vm-routes-in in
  
  # Redistribute VM routes to lab network
  redistribute connected
  redistribute static
  network 192.168.100.0/24  # VM subnet
 exit-address-family

# Route map for VM subnet filtering
route-map vm-routes-in permit 10
 match ip address prefix-list vm-subnets
 set local-preference 200

# Prefix list for VM subnets
ip prefix-list vm-subnets seq 5 permit 192.168.100.0/24 le 32

line vty
```

### **C. kube-burner Configuration on Workload Node**
```yaml
# kube-burner configuration for VM-BGP testing
apiVersion: v1
kind: ConfigMap
metadata:
  name: vm-bgp-kube-burner-config
  namespace: workload-testing
data:
  vm-bgp-test.yml: |
    global:
      writeToFile: true
      metricsDirectory: /tmp/vm-bgp-metrics
      indexerConfig:
        enabled: true
        esServers: ["<es_server>"]
        insecureSkipVerify: true
        defaultIndex: vm-bgp-performance
        type: elastic
    
    jobs:
    - name: vm-bgp-connectivity-test
      jobType: create
      jobIterations: 10  # Test 10 VMs
      qps: 5
      burst: 10
      namespacedIterations: true
      namespace: vm-bgp-test
      podWait: false
      waitWhenFinished: true
      preLoadImages: true
      churn: false
      
      objects:
      # IPAMClaim for each VM
      - objectTemplate: vm-ipclaim.yml
        replicas: 1
        
      # VM with BGP-advertised IP
      - objectTemplate: vm-bgp-instance.yml
        replicas: 1
        
      # Connectivity validation pod
      - objectTemplate: vm-connectivity-test.yml
        replicas: 1
        
    - name: bgp-route-validation
      jobType: create
      jobIterations: 1
      namespace: bgp-validation
      
      objects:
      # BGP route checker
      - objectTemplate: bgp-route-validator.yml
        replicas: 1
```

### **D. Workload Node Deployment Script**
```bash
#!/bin/bash
# deploy-workload-node.sh - Setup workload baremetal node

set -euo pipefail

WORKLOAD_NODE_IP="198.18.0.155"
CLUSTER_MASTERS="198.18.0.1,198.18.0.2,198.18.0.3"
LAB_ALLOCATION="scale-lab-001"

echo "🏗️  Configuring Workload Baremetal Node: ${WORKLOAD_NODE_IP}"
echo "📍 Lab Allocation: ${LAB_ALLOCATION}"
echo "🔗 Cluster Masters: ${CLUSTER_MASTERS}"

# 1. Label the workload node (if part of cluster)
if oc get nodes | grep -q "${WORKLOAD_NODE_IP}"; then
    echo "📋 Labeling workload node in cluster..."
    oc label node $(oc get nodes -o wide | grep "${WORKLOAD_NODE_IP}" | awk '{print $1}') \
        node-role.kubernetes.io/workload-baremetal="" \
        lab-allocation="${LAB_ALLOCATION}" \
        node-purpose="frr-kube-burner"
fi

# 2. Deploy External FRR Container
echo "🌐 Deploying External FRR on workload node..."
cat > /tmp/workload-frr-deployment.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: workload-frr
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: workload-frr-config
  namespace: workload-frr
data:
  frr.conf: |
    frr version 8.4
    frr defaults traditional
    hostname workload-frr-external
    service integrated-vtysh-config
    
    router bgp 64512
     bgp router-id ${WORKLOAD_NODE_IP}
     bgp log-neighbor-changes
     
     $(echo "${CLUSTER_MASTERS}" | tr ',' '\n' | while read master; do
         echo "neighbor ${master} remote-as 64513"
         echo "neighbor ${master} description \"OCP Master\""
         echo "neighbor ${master} timers 3 9"
     done)
     
     address-family ipv4 unicast
      $(echo "${CLUSTER_MASTERS}" | tr ',' '\n' | while read master; do
          echo "neighbor ${master} route-map vm-routes-in in"
      done)
      redistribute connected
      network 192.168.100.0/24
     exit-address-family
    
    route-map vm-routes-in permit 10
     match ip address prefix-list vm-subnets
     set local-preference 200
    
    ip prefix-list vm-subnets seq 5 permit 192.168.100.0/24 le 32
    
    line vty
  daemons: |
    bgpd=yes
    ospfd=no
    ospf6d=no
    ripd=no
    ripngd=no
    isisd=no
    pimd=no
    ldpd=no
    nhrpd=no
    eigrpd=no
    babeld=no
    sharpd=no
    pbrd=no
    bfdd=no
    fabricd=no
    vrrpd=no
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-frr-workload
  namespace: workload-frr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: external-frr-workload
  template:
    metadata:
      labels:
        app: external-frr-workload
    spec:
      nodeSelector:
        node-role.kubernetes.io/workload-baremetal: ""
      hostNetwork: true
      containers:
      - name: frr
        image: quay.io/frrouting/frr:latest
        securityContext:
          privileged: true
        volumeMounts:
        - name: frr-config
          mountPath: /etc/frr
      volumes:
      - name: frr-config
        configMap:
          name: workload-frr-config
EOF

oc apply -f /tmp/workload-frr-deployment.yaml

# 3. Deploy kube-burner for VM testing
echo "🧪 Configuring kube-burner for VM-BGP testing..."
cat > /tmp/kube-burner-vm-bgp.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: workload-testing
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-burner-vm-bgp
  namespace: workload-testing
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner-vm-bgp
rules:
- apiGroups: ["*"]
  resources: ["*"] 
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-burner-vm-bgp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-burner-vm-bgp
subjects:
- kind: ServiceAccount
  name: kube-burner-vm-bgp
  namespace: workload-testing
---
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-burner-vm-bgp-test
  namespace: workload-testing
spec:
  template:
    spec:
      serviceAccountName: kube-burner-vm-bgp
      nodeSelector:
        node-role.kubernetes.io/workload-baremetal: ""
      containers:
      - name: kube-burner
        image: quay.io/cloud-bulldozer/kube-burner-ocp:latest
        env:
        - name: WORKLOAD_NODE
          value: "${WORKLOAD_NODE_IP}"
        - name: ES_SERVER
          value: "<es_server>"
        command:
        - /bin/bash
        - -c
        - |
          echo "🧪 Starting VM-BGP Performance Test from Workload Node: \${WORKLOAD_NODE}"
          
          # Run VM-BGP specific test
          bin/amd64/kube-burner-ocp vm-bgp \\
            --iterations 10 \\
            --es-server \${ES_SERVER} \\
            --es-index vm-bgp-workload-node \\
            --profile-type vm-bgp \\
            --log-level debug \\
            --workload-node \${WORKLOAD_NODE}
            
          echo "✅ VM-BGP test completed on workload node"
      restartPolicy: Never
EOF

oc apply -f /tmp/kube-burner-vm-bgp.yaml

# 4. Verify workload node setup
echo "🔍 Verifying workload node configuration..."

echo "📋 Workload node labels:"
oc get nodes -l node-role.kubernetes.io/workload-baremetal --show-labels

echo "🌐 FRR deployment status:"
oc get pods -n workload-frr

echo "🧪 kube-burner job status:"
oc get jobs -n workload-testing

echo "✅ Workload baremetal node setup complete!"
echo ""
echo "🔗 Next steps:"
echo "1. Verify BGP session: oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp summary'"
echo "2. Check route advertisements: oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp'"
echo "3. Run VM-BGP test: oc create job --from=job/kube-burner-vm-bgp-test vm-bgp-run-001 -n workload-testing"
echo "4. Monitor performance: oc logs -f job/vm-bgp-run-001 -n workload-testing"
```

## 🧪 **VM-BGP Testing with Workload Node**

### **A. Test VM Deployment from Workload Node**
```bash
# VM test deployment controlled from workload node
#!/bin/bash
# test-vm-bgp-workload.sh

WORKLOAD_NODE="198.18.0.155"
TEST_VMS=5
VM_SUBNET="192.168.100.0/24"

echo "🧪 Testing VM-BGP from Workload Node: ${WORKLOAD_NODE}"

# 1. Deploy test VMs with IPAMClaims
for i in $(seq 1 ${TEST_VMS}); do
    VM_IP="192.168.100.$((10 + i))"
    
    cat <<EOF | oc apply -f -
apiVersion: ipam.cluster.x-k8s.io/v1alpha1
kind: IPAMClaim
metadata:
  name: test-vm-${i}-ip
  namespace: vm-bgp-test
spec:
  poolRef:
    name: vm-bgp-ip-pool
  staticIP: "${VM_IP}"
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm-${i}
  namespace: vm-bgp-test
  annotations:
    ovn.org/bgp-advertise-ip: "${VM_IP}/32"
spec:
  running: true
  template:
    spec:
      networks:
      - name: vm-bgp-network
        multus:
          networkName: vm-bgp-network
      domain:
        devices:
          interfaces:
          - name: vm-bgp-network
            bridge: {}
            ipamClaimRef:
              name: test-vm-${i}-ip
EOF
    
    echo "✅ Deployed test VM ${i} with IP ${VM_IP}"
done

# 2. Validate BGP routes from workload node
echo "🔍 Checking BGP routes on workload node..."
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp 192.168.100.0/24 longer-prefixes"

# 3. Test connectivity from workload node
echo "🌐 Testing VM connectivity from workload node..."
for i in $(seq 1 ${TEST_VMS}); do
    VM_IP="192.168.100.$((10 + i))"
    
    # Test from workload node to VM (should be directly routed)
    if ping -c 3 -W 5 "${VM_IP}"; then
        echo "✅ VM ${i} (${VM_IP}) reachable from workload node"
    else
        echo "❌ VM ${i} (${VM_IP}) NOT reachable from workload node"
    fi
done

# 4. Performance test from workload node
echo "⚡ Running performance test from workload node..."
oc create job --from=job/kube-burner-vm-bgp-test "vm-bgp-perf-$(date +%s)" -n workload-testing
```

### **B. BGP Route Validation**
```bash
# Validate BGP routing between cluster and workload node
#!/bin/bash
# validate-bgp-workload.sh

echo "🔍 BGP Session Validation: Cluster ↔ Workload Node"

# 1. Check BGP sessions from OpenShift cluster perspective
echo "📡 Cluster BGP Status (OVN-K8s):"
oc logs -n openshift-ovn-kubernetes deployment/ovnkube-control-plane | grep -i bgp | tail -10

# 2. Check BGP sessions from workload node perspective  
echo "📡 Workload Node BGP Status (External FRR):"
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp summary"

# 3. Verify VM subnet advertisements
echo "📋 VM Subnet Route Advertisements:"
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp 192.168.100.0/24 longer-prefixes"

# 4. Check route convergence time
echo "⏱️  Route Convergence Test:"
for i in {1..5}; do
    echo "Test ${i}: Creating VM and measuring BGP convergence..."
    
    start_time=$(date +%s)
    
    # Create test VM
    oc run bgp-test-vm-${i} --image=registry.access.redhat.com/ubi8/ubi-minimal:latest \
        --overrides='{"spec": {"networks": [{"name": "vm-bgp-network", "multus": {"networkName": "vm-bgp-network"}}]}}' \
        --namespace=vm-bgp-test
    
    # Wait for BGP route to appear
    while ! oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp" | grep -q "192.168.100"; do
        sleep 1
    done
    
    end_time=$(date +%s)
    convergence_time=$((end_time - start_time))
    
    echo "✅ BGP convergence time for VM ${i}: ${convergence_time} seconds"
    
    # Cleanup
    oc delete pod bgp-test-vm-${i} -n vm-bgp-test
    
    sleep 5  # Wait between tests
done
```

## 📊 **Workload Node Monitoring**

### **A. Performance Metrics Collection**
```yaml
# Monitoring setup for workload baremetal node
apiVersion: v1
kind: ConfigMap
metadata:
  name: workload-node-monitoring
  namespace: workload-frr
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      
    scrape_configs:
    - job_name: 'workload-frr-bgp'
      static_configs:
      - targets: ['198.18.0.155:9342']  # FRR BGP metrics
      metrics_path: /metrics
      
    - job_name: 'workload-node-system' 
      static_configs:
      - targets: ['198.18.0.155:9100']  # Node exporter
      
    - job_name: 'kube-burner-results'
      static_configs:
      - targets: ['198.18.0.155:8080']  # kube-burner metrics
```

### **B. Expected Performance Characteristics**
```
Workload Baremetal Node Performance Profile:
┌─────────────────────────────────────────────────────────────────┐
│ Component              │ CPU Usage  │ Memory    │ Network        │
├─────────────────────────────────────────────────────────────────┤
│ External FRR (Idle)    │ 0.1-0.5%   │ 50-100MB  │ <1 Mbps        │
│ External FRR (Active)  │ 1-3%       │ 200-500MB │ 10-50 Mbps     │
│ kube-burner (Running)  │ 50-80%     │ 2-8 GB    │ 100-1000 Mbps  │
│ BGP Route Processing   │ 0.5-2%     │ 100-300MB │ 1-10 Mbps      │
│ System Overhead        │ 5-10%      │ 1-2 GB    │ 50-100 Mbps    │
├─────────────────────────────────────────────────────────────────┤
│ TOTAL (Peak)           │ 60-95%     │ 4-12 GB   │ 200-1200 Mbps  │
└─────────────────────────────────────────────────────────────────┘

BGP Session Characteristics:
- Session Establishment: <10 seconds
- Route Convergence: <5 seconds per VM
- Route Advertisement Latency: <1 second
- BGP Session Stability: >99.9% uptime
- Maximum VM Routes: 1000+ /32 routes
```

## 🎯 **Deployment Checklist**

### **✅ Pre-Deployment Validation**
```bash
# Workload node readiness checklist
echo "🔍 Workload Baremetal Node Pre-Deployment Checklist"

# 1. Verify node is NOT the bastion/deployment host
BASTION_IP=$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIP}')
WORKLOAD_IP="198.18.0.155"

if [ "${BASTION_IP}" = "${WORKLOAD_IP}" ]; then
    echo "❌ ERROR: Workload node cannot be the bastion host!"
    exit 1
else
    echo "✅ Workload node (${WORKLOAD_IP}) is separate from bastion (${BASTION_IP})"
fi

# 2. Verify L2 connectivity
echo "🌐 Testing L2 connectivity to cluster masters..."
for master in 198.18.0.1 198.18.0.2 198.18.0.3; do
    if ping -c 1 -W 3 "${master}"; then
        echo "✅ L2 connectivity to master ${master}"
    else
        echo "❌ No L2 connectivity to master ${master}"
        exit 1
    fi
done

# 3. Verify resource availability
echo "💾 Checking workload node resources..."
CPU_CORES=$(nproc)
MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
DISK_GB=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')

if [ "${CPU_CORES}" -ge 8 ] && [ "${MEMORY_GB}" -ge 16 ] && [ "${DISK_GB}" -ge 100 ]; then
    echo "✅ Resource requirements met: ${CPU_CORES} CPU, ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk"
else
    echo "❌ Insufficient resources: Need 8+ CPU, 16+ GB RAM, 100+ GB disk"
    exit 1
fi

echo "✅ Workload baremetal node ready for FRR + kube-burner deployment"
```

This **workload baremetal node** architecture ensures:

1. **🏗️ Proper Isolation**: FRR and kube-burner run on dedicated hardware, not the deployment bastion
2. **⚡ Performance**: Co-located FRR and testing tools minimize network latency  
3. **🔧 Scale**: Dedicated resources for both BGP processing and performance testing
4. **🎯 Validation**: kube-burner can directly validate VM connectivity from the BGP endpoint

**The workload node becomes your VM-BGP testing and routing hub within the same lab allocation!** 🚀 