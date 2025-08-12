# Integrating VMs with OVN-Kubernetes BGP Infrastructure

## 🎯 **Integration Overview**

**Goal**: Connect unNATed VMs on L2 CUDNs to existing OVN-K8s BGP infrastructure for direct external connectivity

### **Existing Foundation + VM Requirements**
```
┌─────────────────────────────────────────────────────────────────┐
│              Existing OVN-K8s BGP (✅ Available)               │
│                                                                 │
│  OVN-K8s Cluster → FRR Provider → Route Ads → External FRR     │
│       ↑              ↑              ↑            ↑              │
│   BGP Enabled    Integrated     Automatic    ASN 64512         │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│                   VM Integration (🚧 To Build)                 │
│                                                                 │
│  VM + IPAMClaim → L2 CUDN → BGP Route Policy → VM Route Ads    │
│        ↑            ↑           ↑                ↑              │
│   Static IP    UDN Bridge   Selective Ads   External Access    │
└─────────────────────────────────────────────────────────────────┘
```

## 🔧 **Integration Architecture**

### **Complete Data Flow with Workload Baremetal Node**
```
VM (192.168.100.10) 
    ↓ L2 CUDN Bridge
UDN Network (192.168.100.0/24)
    ↓ OVN Logical Switch
OVN-K8s BGP Controller (OpenShift Cluster)
    ↓ BGP Session (iBGP/eBGP)
┌─────────────────────────────────────────────────────────────┐
│              WORKLOAD BAREMETAL NODE                        │
│  ┌─────────────────────┐  ┌─────────────────────────────┐   │
│  │ External FRR        │  │ kube-burner                 │   │
│  │ Container           │  │ Performance Testing         │   │
│  │ (ASN 64512)         │  │ & Validation                │   │
│  │ 198.18.0.155        │  │                             │   │
│  └─────────────────────┘  └─────────────────────────────┘   │
│              ↓ Route Redistribution                         │
└─────────────────────────────────────────────────────────────┘
    ↓ External Network Infrastructure
External Lab Network / Performance Testing Targets
    ↓ Direct Routing
External Clients → VM (unNATed)
```

## 🏗️ **Step-by-Step Integration**

### **Phase 1: UDN Configuration for BGP**

#### **A. BGP-Aware UDN Definition**
```yaml
# UDN with BGP route advertisement capability
apiVersion: k8s.ovn.org/v1
kind: UserDefinedNetwork
metadata:
  name: vm-bgp-udn
  annotations:
    # Enable BGP advertisement for this UDN
    ovn.org/bgp-advertise: "true"
    ovn.org/bgp-advertise-subnet: "192.168.100.0/24"
    ovn.org/bgp-advertise-policy: "vm-subnet-only"
spec:
  topology: Layer2
  layer2:
    role: Primary
    subnets:
    - "192.168.100.0/24"  # VM IP range for BGP advertisement
    excludeSubnets:
    - "192.168.100.1/32"  # Reserve gateway IP
  joinSubnets:
  - "100.64.0.0/16"      # Join to cluster network for BGP
```

#### **B. NetworkAttachmentDefinition**
```yaml
# Network attachment for VMs
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vm-bgp-network
  namespace: vm-workloads
  annotations:
    # Link to BGP-enabled UDN
    k8s.v1.cni.cncf.io/resourceName: ovn-k8s.io/vm-bgp-udn
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "vm-bgp-network",
      "type": "ovn-k8s-cni-overlay",
      "topology": "layer2",
      "netAttachDefName": "vm-workloads/vm-bgp-network",
      "subnets": "192.168.100.0/24",
      "excludeSubnets": "192.168.100.1/32",
      "role": "primary",
      "bgp": {
        "advertise": true,
        "subnet": "192.168.100.0/24"
      }
    }
```

### **Phase 2: IPAMClaim Integration**

#### **A. IP Pool for VM Static IPs**
```yaml
# InClusterIPPool for VM Day0 IPs
apiVersion: ipam.cluster.x-k8s.io/v1alpha1
kind: InClusterIPPool
metadata:
  name: vm-bgp-ip-pool
  namespace: vm-workloads
spec:
  addresses:
  - 192.168.100.10-192.168.100.100  # VM IP range
  prefix: 24
  gateway: 192.168.100.1
  dnsServers:
  - 8.8.8.8
  - 8.8.4.4
  pools:
  - name: vm-pool
    start: 192.168.100.10
    end: 192.168.100.100
    bgpAdvertise: true  # Mark for BGP advertisement
```

#### **B. VM with IPAMClaim**
```yaml
# IPAMClaim for static VM IP
apiVersion: ipam.cluster.x-k8s.io/v1alpha1
kind: IPAMClaim
metadata:
  name: web-vm-ip-claim
  namespace: vm-workloads
  annotations:
    # BGP advertisement hint
    ovn.org/bgp-advertise-route: "true"
spec:
  poolRef:
    apiVersion: ipam.cluster.x-k8s.io/v1alpha1
    kind: InClusterIPPool
    name: vm-bgp-ip-pool
  staticIP: "192.168.100.10"  # Day0 assignment
---
# VM using the claimed IP
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: web-server-vm
  namespace: vm-workloads
  annotations:
    # BGP route advertisement metadata
    ovn.org/bgp-advertise-ip: "192.168.100.10/32"
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
            # Reference to IPAMClaim
            ipamClaimRef:
              name: web-vm-ip-claim
      volumes:
      - name: disk0
        dataVolume:
          name: web-vm-disk
```

### **Phase 3: BGP Route Policy Integration**

#### **A. BGP Advertisement Policy**
```yaml
# BGP Route Advertisement Policy for VM subnets
apiVersion: frr.metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: vm-subnet-advertisement
  namespace: openshift-frr-k8s
spec:
  # Advertise VM subnet to external BGP peers
  ipAddressPools:
  - vm-ip-pool
  peers:
  - external-frr-peer
  nodeSelectors:
  - matchLabels:
      node-role.kubernetes.io/worker: ""
  advertisements:
  - subnet: "192.168.100.0/24"
    type: "vm-subnet"
    communities:
    - "64512:100"  # VM route community
```

#### **B. External FRR Peer Configuration**
```yaml
# External FRR peer for VM routes
apiVersion: frr.metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: external-frr-peer
  namespace: openshift-frr-k8s
spec:
  myASN: 64513        # Cluster ASN
  peerASN: 64512      # External FRR ASN (from existing setup)
  peerAddress: 198.18.0.155  # Workload node IP
  sourceAddress: 198.18.0.1  # Cluster network interface
  routerID: 198.18.0.1
  keepaliveTime: 3s
  holdTime: 9s
  # Accept VM subnet advertisements
  ebgpMultihop: 1
  advertisements:
  - subnet: "192.168.100.0/24"
```

### **Phase 4: OVN-BGP Integration Controller**

#### **A. VM Lifecycle Controller**
```yaml
# Custom controller to handle VM BGP lifecycle
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-bgp-controller
  namespace: openshift-frr-k8s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vm-bgp-controller
  template:
    spec:
      containers:
      - name: controller
        image: vm-bgp-controller:latest
        env:
        - name: CLUSTER_NAME
          value: "ovn-bgp-cluster"
        - name: BGP_ASN
          value: "64513"
        - name: VM_SUBNET
          value: "192.168.100.0/24"
        command:
        - /manager
        args:
        - --enable-vm-bgp=true
        - --bgp-peer-ip=198.18.0.155
        - --vm-ip-pool=vm-bgp-ip-pool
```

#### **B. Controller Logic (Pseudo-code)**
```go
// VM-BGP Controller Logic
func (r *VMReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    vm := &kubevirtv1.VirtualMachine{}
    if err := r.Get(ctx, req.NamedspacedName, vm); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Handle VM creation/update
    if vm.DeletionTimestamp.IsZero() {
        return r.handleVMCreate(ctx, vm)
    }
    
    // Handle VM deletion
    return r.handleVMDelete(ctx, vm)
}

func (r *VMReconciler) handleVMCreate(ctx context.Context, vm *kubevirtv1.VirtualMachine) (ctrl.Result, error) {
    // Get VM IP from IPAMClaim
    vmIP := r.getVMIP(vm)
    
    // Create BGP route advertisement for VM /32
    route := &frrv1beta1.BGPAdvertisement{
        ObjectMeta: metav1.ObjectMeta{
            Name:      fmt.Sprintf("vm-%s-route", vm.Name),
            Namespace: "openshift-frr-k8s",
        },
        Spec: frrv1beta1.BGPAdvertisementSpec{
            Subnet: fmt.Sprintf("%s/32", vmIP),
            Type:   "vm-host-route",
            Communities: []string{"64512:200"}, // VM host route community
        },
    }
    
    return ctrl.Result{}, r.Create(ctx, route)
}

func (r *VMReconciler) handleVMDelete(ctx context.Context, vm *kubevirtv1.VirtualMachine) (ctrl.Result, error) {
    // Withdraw BGP route for deleted VM
    routeName := fmt.Sprintf("vm-%s-route", vm.Name)
    route := &frrv1beta1.BGPAdvertisement{}
    
    if err := r.Get(ctx, types.NamespacedName{Name: routeName, Namespace: "openshift-frr-k8s"}, route); err == nil {
        return ctrl.Result{}, r.Delete(ctx, route)
    }
    
    return ctrl.Result{}, nil
}
```

## 🔄 **Integration with Existing BGP Setup**

### **A. Leverage Existing External FRR**
```bash
# Modify existing External FRR to accept VM routes
# (Add to existing vtysh configuration)
vtysh
configure terminal
router bgp 64512

# Accept VM subnet advertisements from cluster
neighbor 198.18.0.1 remote-as 64513
neighbor 198.18.0.1 route-map vm-routes-in in

# Define route map for VM subnets
route-map vm-routes-in permit 10
 match community 64512:100  # VM subnet community
 set local-preference 200   # Higher preference for VM routes

route-map vm-routes-in permit 20  
 match community 64512:200  # VM host routes
 set local-preference 250   # Highest preference for specific VMs

# Redistribute VM routes to external network
redistribute bgp
end
```

### **B. Update Existing Kube-burner Test**
```bash
# Modified kube-burner test to include VM BGP validation
bin/amd64/kube-burner-ocp udn-bgp \
  --iterations 72 \
  --check-health=false \
  --es-server=<es_server> \
  --es-index=ripsaw-kube-burner-vm-bgp \
  --profile-type=vm-bgp \
  --log-level=debug \
  --vm-count=10 \
  --vm-ip-range=192.168.100.10-192.168.100.100
```

## 📊 **Expected Integration Outcomes**

### **A. Traffic Flow Validation**
```bash
# Test unNATed VM connectivity
# From external network to VM
curl http://192.168.100.10    # Direct access, no NAT

# From VM to external network  
# (Inside VM)
curl http://8.8.8.8          # Direct egress, no NAT

# BGP route verification
# On external FRR node
vtysh -c "show ip bgp"       # Should show 192.168.100.0/24 and /32 routes
```

### **B. Performance Characteristics**
```
Expected Results:
┌─────────────────────────────────────────────────────────────────┐
│ Metric                    │ Without BGP  │ With BGP    │ Change │
├─────────────────────────────────────────────────────────────────┤
│ VM-to-External Latency    │ High (NAT)   │ Low (Direct)│ -30%   │
│ External-to-VM Latency    │ N/A          │ Direct      │ +100%  │
│ Throughput                │ NAT Limited  │ Line Rate   │ +50%   │
│ Route Convergence         │ N/A          │ <5s         │ New    │
│ BGP Session Stability     │ N/A          │ >99%        │ New    │
└─────────────────────────────────────────────────────────────────┘
```

## 🚨 **Integration Challenges & Solutions**

### **Challenge 1: VM IP Route Advertisement**
**Problem**: Individual VM IPs need /32 route advertisement
**Solution**: VM lifecycle controller manages per-VM BGP advertisements

### **Challenge 2: Route Scale**  
**Problem**: Many VMs = many /32 routes
**Solution**: Route aggregation + selective advertisement policies

### **Challenge 3: VM Migration**
**Problem**: VM migration breaks BGP route next-hop
**Solution**: Controller updates BGP next-hop on VM migration events

### **Challenge 4: Day0 IP Persistence**
**Problem**: IPAMClaim IPs must survive cluster operations
**Solution**: Persistent storage for IPAMClaim + BGP route mappings

## 🎯 **Implementation Roadmap**

### **Phase 1: Foundation (Week 1-2)**
```bash
# 1. Verify existing BGP setup
oc get network.operator.openshift.io cluster -o yaml | grep -A5 additionalRoutingCapabilities

# 2. Create UDN with BGP annotations
oc apply -f vm-bgp-udn.yaml

# 3. Deploy test VM with IPAMClaim
oc apply -f test-vm-with-ipclaim.yaml

# 4. Verify UDN-BGP integration
oc logs -n openshift-frr-k8s deployment/frr-k8s
```

### **Phase 2: Controller Development (Week 3-4)**
```bash
# 1. Build VM-BGP lifecycle controller
make build-vm-bgp-controller

# 2. Deploy controller
oc apply -f vm-bgp-controller.yaml

# 3. Test VM lifecycle events
oc create -f test-vm.yaml    # Should advertise route
oc delete -f test-vm.yaml    # Should withdraw route
```

### **Phase 3: Scale & Testing (Week 5-6)**
```bash
# 1. Scale test with multiple VMs
./deploy-test-vms.sh --count=10

# 2. BGP route verification
vtysh -c "show ip bgp 192.168.100.0/24 longer-prefixes"

# 3. Performance validation
./test-vm-connectivity.sh --external-client=true
```

### **Phase 4: Production Hardening (Week 7-8)**
```bash
# 1. Add monitoring & alerting
oc apply -f vm-bgp-monitoring.yaml

# 2. Implement backup/recovery
./backup-vm-ip-mappings.sh

# 3. Documentation & runbooks
./generate-vm-bgp-docs.sh
```

## 🔍 **Monitoring & Troubleshooting**

### **BGP Session Monitoring**
```bash
# Check OVN-K8s BGP status
oc logs -n openshift-ovn-kubernetes deployment/ovnkube-control-plane | grep bgp

# Check FRR BGP sessions
oc exec -n openshift-frr-k8s deployment/frr-k8s -- vtysh -c "show ip bgp summary"

# Verify VM route advertisements
oc exec -n openshift-frr-k8s deployment/frr-k8s -- vtysh -c "show ip bgp 192.168.100.0/24 longer-prefixes"
```

### **VM Connectivity Validation**
```bash
# Test VM reachability from external
ping 192.168.100.10

# Test VM egress (no NAT)
oc exec vm-web-server-vm -- curl -I http://httpbin.org/ip
# Should return VM's actual IP (192.168.100.10), not NAT IP
```

This integration leverages the existing OVN-Kubernetes BGP infrastructure while adding the VM-specific components needed for unNATed connectivity with Day0 IP allocation! 🚀 