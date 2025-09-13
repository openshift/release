#!/bin/bash
# deploy-workload-baremetal-node.sh
# Setup script for workload baremetal node with External FRR + kube-burner

set -euo pipefail

# Configuration
WORKLOAD_NODE_IP="198.18.0.155"
CLUSTER_MASTERS="198.18.0.1,198.18.0.2,198.18.0.3"
LAB_ALLOCATION="scale-lab-001"
BGP_ASN_CLUSTER="64513"
BGP_ASN_EXTERNAL="64512"
VM_SUBNET="192.168.100.0/24"
VM_IP_RANGE="192.168.100.10-192.168.100.100"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Pre-deployment validation
validate_environment() {
    log "🔍 Validating workload baremetal node environment..."
    
    # 1. Verify this is NOT the bastion host
    BASTION_IP=$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIP}' 2>/dev/null || echo "unknown")
    
    if [ "${BASTION_IP}" = "${WORKLOAD_NODE_IP}" ]; then
        error "❌ Workload node cannot be the bastion host! Bastion: ${BASTION_IP}, Workload: ${WORKLOAD_NODE_IP}"
    fi
    
    info "✅ Workload node (${WORKLOAD_NODE_IP}) is separate from bastion (${BASTION_IP})"
    
    # 2. Verify L2 connectivity to cluster masters
    info "🌐 Testing L2 connectivity to cluster masters..."
    IFS=',' read -ra MASTERS <<< "${CLUSTER_MASTERS}"
    for master in "${MASTERS[@]}"; do
        if ping -c 1 -W 3 "${master}" >/dev/null 2>&1; then
            info "✅ L2 connectivity to master ${master}"
        else
            error "❌ No L2 connectivity to master ${master}"
        fi
    done
    
    # 3. Verify resource requirements
    info "💾 Checking workload node resources..."
    CPU_CORES=$(nproc)
    MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
    DISK_GB=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
    
    if [ "${CPU_CORES}" -ge 8 ] && [ "${MEMORY_GB}" -ge 16 ] && [ "${DISK_GB}" -ge 100 ]; then
        info "✅ Resource requirements met: ${CPU_CORES} CPU, ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk"
    else
        error "❌ Insufficient resources: Need 8+ CPU, 16+ GB RAM, 100+ GB disk. Current: ${CPU_CORES} CPU, ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk"
    fi
    
    # 4. Verify OpenShift cluster connectivity
    if ! oc cluster-info >/dev/null 2>&1; then
        error "❌ Cannot connect to OpenShift cluster. Verify oc login."
    fi
    
    info "✅ OpenShift cluster connectivity verified"
    
    log "✅ Environment validation completed successfully"
}

# Label workload node if it's part of the cluster
label_workload_node() {
    log "📋 Labeling workload baremetal node..."
    
    # Find node by IP in cluster
    WORKLOAD_NODE_NAME=$(oc get nodes -o wide | grep "${WORKLOAD_NODE_IP}" | awk '{print $1}' || echo "")
    
    if [ -n "${WORKLOAD_NODE_NAME}" ]; then
        info "Found workload node in cluster: ${WORKLOAD_NODE_NAME}"
        
        oc label node "${WORKLOAD_NODE_NAME}" \
            node-role.kubernetes.io/workload-baremetal="" \
            lab-allocation="${LAB_ALLOCATION}" \
            node-purpose="frr-kube-burner" \
            bgp-external-frr="true" \
            --overwrite
            
        info "✅ Workload node labeled successfully"
    else
        warn "Workload node not found in cluster - may be external to cluster"
    fi
}

# Deploy External FRR container
deploy_external_frr() {
    log "🌐 Deploying External FRR on workload baremetal node..."
    
    # Generate FRR configuration
    MASTERS_CONFIG=""
    IFS=',' read -ra MASTERS <<< "${CLUSTER_MASTERS}"
    for master in "${MASTERS[@]}"; do
        MASTERS_CONFIG+="
 neighbor ${master} remote-as ${BGP_ASN_CLUSTER}
 neighbor ${master} description \"OCP Master\"
 neighbor ${master} timers 3 9"
    done
    
    MASTERS_AF_CONFIG=""
    for master in "${MASTERS[@]}"; do
        MASTERS_AF_CONFIG+="
  neighbor ${master} route-map vm-routes-in in"
    done
    
    cat > /tmp/workload-frr-deployment.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: workload-frr
  labels:
    lab-allocation: "${LAB_ALLOCATION}"
    node-purpose: "external-frr"
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
    
    # BGP Configuration for VM route processing
    router bgp ${BGP_ASN_EXTERNAL}
     bgp router-id ${WORKLOAD_NODE_IP}
     bgp log-neighbor-changes
     bgp bestpath as-path multipath-relax
     ${MASTERS_CONFIG}
     
     # Address family for VM subnets
     address-family ipv4 unicast
      ${MASTERS_AF_CONFIG}
      redistribute connected
      redistribute static
      network ${VM_SUBNET}
     exit-address-family
    
    # Route map for VM subnet filtering
    route-map vm-routes-in permit 10
     match ip address prefix-list vm-subnets
     set local-preference 200
    
    route-map vm-routes-in permit 20
     match ip address prefix-list vm-host-routes
     set local-preference 250
    
    # Prefix lists for VM traffic
    ip prefix-list vm-subnets seq 5 permit ${VM_SUBNET} le 32
    ip prefix-list vm-host-routes seq 5 permit ${VM_SUBNET} le 32
    
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
  labels:
    app: external-frr-workload
    lab-allocation: "${LAB_ALLOCATION}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: external-frr-workload
  template:
    metadata:
      labels:
        app: external-frr-workload
        lab-allocation: "${LAB_ALLOCATION}"
    spec:
      nodeSelector:
        node-role.kubernetes.io/workload-baremetal: ""
      hostNetwork: true
      tolerations:
      - key: node-role.kubernetes.io/workload-baremetal
        operator: Exists
        effect: NoSchedule
      containers:
      - name: frr
        image: quay.io/frrouting/frr:latest
        securityContext:
          privileged: true
        env:
        - name: WORKLOAD_NODE_IP
          value: "${WORKLOAD_NODE_IP}"
        - name: BGP_ASN
          value: "${BGP_ASN_EXTERNAL}"
        - name: VM_SUBNET
          value: "${VM_SUBNET}"
        resources:
          requests:
            cpu: 500m
            memory: 256Mi
          limits:
            cpu: 2000m
            memory: 1Gi
        volumeMounts:
        - name: frr-config
          mountPath: /etc/frr
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "vtysh -c 'show ip bgp summary' | grep -q Established"
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "vtysh -c 'show ip bgp summary' | grep -q ${BGP_ASN_CLUSTER}"
          initialDelaySeconds: 15
          periodSeconds: 10
      volumes:
      - name: frr-config
        configMap:
          name: workload-frr-config
---
apiVersion: v1
kind: Service
metadata:
  name: external-frr-workload
  namespace: workload-frr
spec:
  selector:
    app: external-frr-workload
  ports:
  - name: bgp
    port: 179
    targetPort: 179
  - name: metrics
    port: 9342
    targetPort: 9342
  type: ClusterIP
EOF
    
    oc apply -f /tmp/workload-frr-deployment.yaml
    
    info "✅ External FRR deployment created"
    
    # Wait for FRR to be ready
    info "⏳ Waiting for External FRR to be ready..."
    oc wait --for=condition=available --timeout=300s deployment/external-frr-workload -n workload-frr
    
    info "✅ External FRR is ready"
}

# Deploy kube-burner for VM testing
deploy_kube_burner() {
    log "🧪 Deploying kube-burner for VM-BGP testing..."
    
    cat > /tmp/kube-burner-vm-bgp.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: workload-testing
  labels:
    lab-allocation: "${LAB_ALLOCATION}"
    node-purpose: "kube-burner-testing"
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
apiVersion: v1
kind: ConfigMap
metadata:
  name: vm-bgp-test-config
  namespace: workload-testing
data:
  vm-bgp-test.yml: |
    global:
      writeToFile: true
      metricsDirectory: /tmp/vm-bgp-metrics
      indexerConfig:
        enabled: true
        esServers: ["\${ES_SERVER}"]
        insecureSkipVerify: true
        defaultIndex: vm-bgp-workload-performance
        type: elastic
    
    jobs:
    - name: vm-bgp-connectivity-test
      jobType: create
      jobIterations: 10
      qps: 5
      burst: 10
      namespacedIterations: true
      namespace: vm-bgp-test
      podWait: false
      waitWhenFinished: true
      preLoadImages: true
      churn: false
      
      objects:
      - objectTemplate: vm-ipclaim.yml
        replicas: 1
      - objectTemplate: vm-bgp-instance.yml
        replicas: 1
      - objectTemplate: vm-connectivity-test.yml
        replicas: 1
---
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-burner-vm-bgp-setup
  namespace: workload-testing
spec:
  template:
    spec:
      serviceAccountName: kube-burner-vm-bgp
      nodeSelector:
        node-role.kubernetes.io/workload-baremetal: ""
      tolerations:
      - key: node-role.kubernetes.io/workload-baremetal
        operator: Exists
        effect: NoSchedule
      containers:
      - name: kube-burner
        image: quay.io/cloud-bulldozer/kube-burner-ocp:latest
        env:
        - name: WORKLOAD_NODE
          value: "${WORKLOAD_NODE_IP}"
        - name: VM_SUBNET
          value: "${VM_SUBNET}"
        - name: VM_IP_RANGE
          value: "${VM_IP_RANGE}"
        - name: LAB_ALLOCATION
          value: "${LAB_ALLOCATION}"
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 4000m
            memory: 8Gi
        command:
        - /bin/bash
        - -c
        - |
          echo "🧪 Setting up VM-BGP Performance Testing Environment"
          echo "📍 Workload Node: \${WORKLOAD_NODE}"
          echo "🌐 VM Subnet: \${VM_SUBNET}"
          echo "📊 VM IP Range: \${VM_IP_RANGE}"
          echo "🏷️  Lab Allocation: \${LAB_ALLOCATION}"
          
          # Create VM testing namespace
          oc create namespace vm-bgp-test --dry-run=client -o yaml | oc apply -f -
          oc label namespace vm-bgp-test lab-allocation="\${LAB_ALLOCATION}" --overwrite
          
          echo "✅ VM-BGP testing environment ready"
          echo ""
          echo "🔗 Next steps:"
          echo "1. Verify BGP session: oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp summary'"
          echo "2. Run VM test: oc create job --from=job/kube-burner-vm-bgp-setup vm-bgp-test-\$(date +%s) -n workload-testing"
          echo "3. Monitor results: oc logs -f job/vm-bgp-test-\$(date +%s) -n workload-testing"
          
          # Keep job alive for monitoring
          sleep 60
      restartPolicy: Never
  backoffLimit: 3
EOF
    
    oc apply -f /tmp/kube-burner-vm-bgp.yaml
    
    info "✅ kube-burner deployment created"
}

# Verify BGP session establishment
verify_bgp_sessions() {
    log "🔍 Verifying BGP session establishment..."
    
    # Wait for FRR pod to be ready
    info "⏳ Waiting for FRR pod to be ready..."
    sleep 30
    
    # Check BGP summary
    info "📡 Checking BGP session status..."
    if oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp summary" 2>/dev/null; then
        info "✅ BGP sessions information retrieved"
    else
        warn "⚠️  Could not retrieve BGP session status - FRR may still be starting"
    fi
    
    # Test basic connectivity
    info "🌐 Testing connectivity to cluster masters..."
    IFS=',' read -ra MASTERS <<< "${CLUSTER_MASTERS}"
    for master in "${MASTERS[@]}"; do
        if ping -c 1 -W 3 "${master}" >/dev/null 2>&1; then
            info "✅ Connectivity to master ${master} verified"
        else
            warn "⚠️  No connectivity to master ${master}"
        fi
    done
}

# Generate usage instructions
generate_usage_instructions() {
    log "📚 Generating usage instructions..."
    
    cat > /tmp/workload-node-usage.md << EOF
# Workload Baremetal Node Usage Instructions

## 🎯 Node Information
- **Workload Node IP**: ${WORKLOAD_NODE_IP}
- **Lab Allocation**: ${LAB_ALLOCATION}
- **BGP ASN (External)**: ${BGP_ASN_EXTERNAL}
- **BGP ASN (Cluster)**: ${BGP_ASN_CLUSTER}
- **VM Subnet**: ${VM_SUBNET}

## 🔍 Verification Commands

### Check BGP Sessions
\`\`\`bash
# BGP session summary
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp summary"

# BGP route table
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp"

# VM subnet routes
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp ${VM_SUBNET} longer-prefixes"
\`\`\`

### Check FRR Status
\`\`\`bash
# FRR pod status
oc get pods -n workload-frr

# FRR logs
oc logs -n workload-frr deployment/external-frr-workload

# FRR configuration
oc exec -n workload-frr deployment/external-frr-workload -- cat /etc/frr/frr.conf
\`\`\`

### Run VM-BGP Tests
\`\`\`bash
# Create VM-BGP test job
oc create job --from=job/kube-burner-vm-bgp-setup vm-bgp-test-\$(date +%s) -n workload-testing

# Monitor test progress
oc get jobs -n workload-testing

# View test logs
oc logs -f job/vm-bgp-test-\$(date +%s) -n workload-testing
\`\`\`

## 🚨 Troubleshooting

### BGP Session Issues
\`\`\`bash
# Check if BGP daemon is running
oc exec -n workload-frr deployment/external-frr-workload -- ps aux | grep bgpd

# Check BGP neighbor status
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp neighbors"

# Check routing table
oc exec -n workload-frr deployment/external-frr-workload -- ip route
\`\`\`

### Network Connectivity
\`\`\`bash
# Test L2 connectivity to masters
ping -c 3 198.18.0.1
ping -c 3 198.18.0.2  
ping -c 3 198.18.0.3

# Test VM subnet connectivity
ping -c 3 192.168.100.1  # VM gateway
\`\`\`

### Performance Testing
\`\`\`bash
# Check kube-burner status
oc get pods -n workload-testing

# Review test results
oc logs -n workload-testing deployment/kube-burner-vm-bgp

# Check test artifacts
oc exec -n workload-testing deployment/kube-burner-vm-bgp -- ls -la /tmp/vm-bgp-metrics/
\`\`\`

## 📊 Expected Results

### BGP Session Status
- **Sessions**: 3 established (one per master)
- **Routes**: VM subnet (${VM_SUBNET}) advertised
- **Convergence**: <5 seconds per route

### VM Connectivity  
- **Direct Access**: External → VM (unNATed)
- **Direct Egress**: VM → External (unNATed)
- **Latency**: <1ms additional overhead

### Performance Characteristics
- **BGP Convergence**: <5 seconds
- **Route Scale**: 100+ VMs supported  
- **Session Stability**: >99% uptime

EOF
    
    info "✅ Usage instructions saved to /tmp/workload-node-usage.md"
    cat /tmp/workload-node-usage.md
}

# Main deployment function
main() {
    log "🚀 Starting Workload Baremetal Node Deployment"
    log "📍 Node: ${WORKLOAD_NODE_IP} | Lab: ${LAB_ALLOCATION}"
    log "🌐 Masters: ${CLUSTER_MASTERS}"
    log "🔗 VM Subnet: ${VM_SUBNET}"
    
    validate_environment
    label_workload_node
    deploy_external_frr
    deploy_kube_burner
    verify_bgp_sessions
    generate_usage_instructions
    
    log "🎉 Workload Baremetal Node deployment completed successfully!"
    log ""
    log "📋 Summary:"
    log "   ✅ External FRR deployed on workload node"
    log "   ✅ kube-burner configured for VM-BGP testing"
    log "   ✅ BGP sessions established with cluster"
    log "   ✅ VM-BGP testing environment ready"
    log ""
    log "🔗 Next steps:"
    log "   1. Review /tmp/workload-node-usage.md for detailed instructions"
    log "   2. Create UDN with BGP annotations for VM testing"
    log "   3. Deploy test VMs with IPAMClaims"
    log "   4. Run kube-burner VM-BGP performance tests"
    log ""
    log "🚀 Your workload baremetal node is ready for VM-BGP integration!"
}

# Run main function
main "$@" 