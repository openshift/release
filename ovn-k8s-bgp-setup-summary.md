# OVN-Kubernetes BGP Feature Setup & Testing Summary

## 🎯 **Overview**
OVN-Kubernetes recently added BGP functionality for bare metal environments. This guide covers setup, configuration, and scale testing with kube-burner.

## 🏗️ **Architecture Requirements**

### **Environment Constraints:**
- ✅ **Bare Metal Only**: BGP feature is exclusive to bare metal deployments
- ✅ **OpenShift 4.20+**: Minimum cluster version required
- ✅ **Dedicated Workload Node**: Separate bare metal node for external FRR + kube-burner
- ❌ **Not Supported**: Virtual environments, cloud deployments

### **Node Topology:**
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Jump Host     │    │  OCP Cluster    │    │ Workload Node   │
│   (Bastion)     │    │  (Control/Work) │    │ (External FRR)  │
│                 │    │                 │    │                 │
│ - Deployment    │    │ - OVN-K8s BGP   │    │ - FRR Container │
│ - kubeconfig    │    │ - Route Ads     │    │ - kube-burner   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                              Network: 198.18.0.0/16
```

## 🔧 **Implementation Steps**

### **Phase 1: Cluster BGP Enablement**

```bash
# Enable FRR and Route Advertisements in OVN-Kubernetes
oc patch Network.operator.openshift.io cluster --type=merge -p='{
  "spec": {
    "additionalRoutingCapabilities": {
      "providers": ["FRR"]
    }, 
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "routeAdvertisements": "Enabled"
      }
    }
  }
}'
```

**What this enables:**
- ✅ FRR (Free Range Routing) integration
- ✅ Route advertisement capability
- ✅ BGP session establishment
- ✅ Dynamic route injection/withdrawal

### **Phase 2: Workload Node Configuration**

#### **A. Package Installation**
```bash
# Essential packages for BGP testing
dnf install vim curl git make binutils bison gcc glibc-devel golang tmux podman jq -y

# OpenShift CLI tools
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz | tar -xvzf -
mv oc kubectl /usr/bin/
```

#### **B. Network Configuration**
```bash
# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -p

# Assign IP in cluster network range (example: 198.18.0.155/16)
ip a a 198.18.0.155/16 brd 198.18.255.255 dev ens1f0

# Copy cluster access configuration
export KUBECONFIG=/root/kubeconfig
```

#### **C. Firewall & Routing Setup**
```bash
# Disable firewalld and configure permissive iptables
sudo iptables -F                    # Flush all rules
sudo iptables -X                    # Delete custom chains  
sudo iptables -P INPUT ACCEPT       # Allow all input
sudo iptables -P FORWARD ACCEPT     # Allow all forwarding
sudo iptables -P OUTPUT ACCEPT      # Allow all output
sudo iptables-save > /etc/sysconfig/iptables
sudo systemctl enable iptables.service
```

### **Phase 3: External FRR Setup**

#### **A. FRR Container Deployment**
```bash
# Clone FRR-K8s integration (requires Go 1.23+)
git clone -b ovnk-bgp https://github.com/jcaamano/frr-k8s
cd frr-k8s/hack/demo
sudo ./demo.sh
```

#### **B. BGP Peer Configuration**
```bash
# Configure cluster as BGP peer
oc apply -n openshift-frr-k8s -f frr-k8s/hack/demo/configs/receive_all.yaml

# Configure FRR for route redistribution
vtysh
configure terminal
router bgp 64512
redistribute static
redistribute connected
end
```

**BGP Session Establishment:**
```
External FRR (ASN 64512) ←→ OVN-Kubernetes BGP (Internal ASN)
         ↓
Route Exchange: OVN routes ↔ External routes
```

### **Phase 4: Scale Testing with Kube-burner**

#### **A. Kube-burner Setup**
```bash
# Build kube-burner-ocp for BGP testing
git clone https://github.com/kube-burner/kube-burner-ocp
cd kube-burner-ocp
make clean; make build
```

#### **B. BGP Scale Test Execution**
```bash
# Run UDN-BGP scale test
bin/amd64/kube-burner-ocp udn-bgp \
  --iterations 72 \
  --check-health=false \
  --es-server=<es_server> \
  --es-index=ripsaw-kube-burner \
  --profile-type=regular \
  --log-level=debug
```

**Test Metrics Focus:**
- 📊 **CPU Usage**: OVNK containers per worker node
- 📊 **Memory Usage**: OVNK containers per worker node  
- 📊 **BGP Routes**: Route advertisement/withdrawal performance
- 📊 **Scale Impact**: Performance with 72 iterations

## 📊 **Key Components & Interactions**

### **OVN-Kubernetes BGP Architecture:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    OVN-Kubernetes Cluster                      │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
│  │   Master    │    │   Worker    │    │   Worker    │        │
│  │             │    │             │    │             │        │
│  │ - OVN-NB    │    │ - ovn-k8s   │    │ - ovn-k8s   │        │
│  │ - OVN-SB    │    │ - FRR       │    │ - FRR       │        │
│  │ - OVN-CNF   │    │ - BGP       │    │ - BGP       │        │
│  └─────────────┘    └─────────────┘    └─────────────┘        │
│                           │                    │               │
└───────────────────────────┼────────────────────┼───────────────┘
                            │                    │
                    ┌───────┴────────────────────┴───────┐
                    │         BGP Sessions               │
                    │                                    │
                ┌───▼────────────────────────────────────▼───┐
                │        External FRR Container             │
                │        (Workload Bare Metal Node)         │
                │                                           │
                │ - BGP ASN: 64512                         │
                │ - Route Redistribution                    │
                │ - kube-burner Scale Testing              │
                └───────────────────────────────────────────┘
```

### **Route Advertisement Flow:**
```
1. Pod/Service Creation → OVN Route Table Update
2. OVN-Kubernetes → FRR BGP Advertisement  
3. External FRR → Route Reception
4. Route Redistribution → External Network
5. kube-burner → Scale Testing (72 iterations)
```

## 🚨 **Critical Requirements & Constraints**

### **✅ Prerequisites:**
- **Bare Metal Environment**: No virtualization support
- **OpenShift 4.20+**: BGP feature availability
- **Dedicated Workload Node**: Not the bastion/jump host
- **Network Connectivity**: Same L2 segment as cluster
- **Go 1.23+**: For FRR-K8s compilation

### **⚠️ Limitations:**
- **Bare Metal Only**: No cloud/virtual environment support
- **Single ASN**: External FRR uses fixed ASN 64512
- **Route Redistribution**: Static and connected routes only
- **Scale Boundary**: Testing limited to 72 iterations

### **🔧 Dependencies:**
- **FRR Container**: External BGP peer requirement
- **Network Reachability**: 198.18.0.0/16 network access
- **Firewall Configuration**: Permissive iptables rules
- **Host Routing**: IP forwarding enabled

## 📈 **Expected Outcomes**

### **BGP Functionality:**
✅ **Route Advertisement**: OVN routes advertised to external peers  
✅ **Route Reception**: External routes injected into OVN  
✅ **Dynamic Updates**: Real-time route addition/removal  
✅ **Scale Testing**: Performance validation with kube-burner  

### **Performance Metrics:**
- **CPU Impact**: OVNK container resource usage
- **Memory Impact**: BGP route table memory consumption
- **Route Convergence**: Time to advertise/withdraw routes
- **Scale Limits**: Maximum routes/sessions sustainable

### **Testing Validation:**
- **72 Iterations**: Scale test completion
- **BGP Sessions**: Stable peer relationships
- **Route Exchange**: Bidirectional route flow
- **Resource Monitoring**: ES/metrics collection

## 🎯 **Use Cases Enabled**

### **Primary Scenarios:**
1. **External Load Balancer Integration**: Direct route advertisement
2. **Multi-Cluster Networking**: BGP-based cluster interconnect
3. **Hybrid Cloud Connectivity**: On-premises to cloud routing
4. **Service Mesh Integration**: External service discovery

### **Scale Testing Focus:**
- **Route Advertisement Performance**: How many routes can be advertised
- **BGP Session Stability**: Peer relationship under load
- **OVNK Resource Consumption**: Memory/CPU impact of BGP
- **Convergence Time**: Speed of route updates

## 🔄 **Operational Considerations**

### **Monitoring Requirements:**
- **BGP Session Status**: Peer up/down monitoring
- **Route Table Size**: Advertised route count tracking
- **OVNK Resource Usage**: Container metrics collection
- **Network Connectivity**: End-to-end reachability validation

### **Troubleshooting:**
- **BGP Session Issues**: Check FRR container logs
- **Route Advertisement Problems**: Verify OVN-NB/SB databases
- **Network Connectivity**: Validate IP forwarding/iptables
- **Performance Issues**: Monitor OVNK container resources

This represents a significant advancement in OVN-Kubernetes networking capabilities, enabling direct BGP integration for bare metal deployments with comprehensive scale testing validation. 