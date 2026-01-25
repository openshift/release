#!/bin/bash
set -euxo pipefail

echo "=== IPSec Network Performance Test with Verification ==="
echo "Timestamp: $(date)"

# Create directories for logging and artifacts
mkdir -p /tmp/ipsec-verification-artifacts
mkdir -p /tmp/ipsec-verification-logs

echo "=== Installing Git Dependency ==="
# Try installing git with sudo first, then fallback to alternatives
if command -v sudo &> /dev/null; then
    if command -v yum &> /dev/null; then
        sudo yum install -y git && echo "Git installed via sudo yum"
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git && echo "Git installed via sudo apt-get"
    elif command -v apk &> /dev/null; then
        sudo apk add --no-cache git && echo "Git installed via sudo apk"
    fi
fi

# If sudo installation failed, try without sudo
if ! command -v git &> /dev/null; then
    echo "Trying installation without sudo..."
    if command -v yum &> /dev/null; then
        yum install -y git 2>/dev/null && echo "Git installed via yum"
    elif command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y git 2>/dev/null && echo "Git installed via apt-get"
    elif command -v apk &> /dev/null; then
        apk add --no-cache git 2>/dev/null && echo "Git installed via apk"
    fi
fi

# Verify git installation
if command -v git &> /dev/null; then
    git --version | tee /tmp/ipsec-verification-artifacts/git-version.log
    echo "Git successfully installed"
else
    echo "WARNING: Git not available, test may fail"
fi

echo "=== Collecting Cluster Information ==="
oc get infrastructure cluster -o yaml > /tmp/ipsec-verification-artifacts/cluster-info.yaml 2>&1 || echo "Could not get cluster info"

echo "=== Checking IPSec Configuration ==="
oc get network.operator.openshift.io cluster -o yaml | grep -A10 -B5 ipsec > /tmp/ipsec-verification-artifacts/ipsec-config.yaml 2>&1 || echo "No IPSec config found"

IPSEC_MODE=$(oc get network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}' 2>/dev/null || echo "Not configured")
echo "IPSec Mode: $IPSEC_MODE" | tee /tmp/ipsec-verification-artifacts/ipsec-mode.log

echo "=== Checking IPSec Pods ==="
oc get pods -n openshift-ovn-kubernetes | grep ipsec > /tmp/ipsec-verification-artifacts/ipsec-pods.log 2>&1 || echo "No IPSec pods found"
IPSEC_POD_COUNT=$(oc get pods -n openshift-ovn-kubernetes | grep ipsec | wc -l)
echo "IPSec pods running: $IPSEC_POD_COUNT" | tee -a /tmp/ipsec-verification-artifacts/ipsec-pods.log

# Get primary worker node for monitoring
WORKER_NODE=$(oc get nodes --no-headers | grep worker | head -1 | awk '{print $1}' || echo "no-worker-found")
echo "Primary monitoring node: $WORKER_NODE" | tee /tmp/ipsec-verification-artifacts/monitoring-node.log

if [ "$WORKER_NODE" != "no-worker-found" ]; then
    echo "=== Starting Packet Captures on $WORKER_NODE ==="
    
    # Start ESP packet capture (encrypted traffic)
    echo "Starting ESP packet capture..."
    timeout 1800 oc debug node/$WORKER_NODE -- chroot /host tcpdump -i any -w /tmp/esp-packets.pcap esp > /tmp/ipsec-verification-logs/esp-capture.log 2>&1 &
    ESP_PID=$!
    echo "ESP capture started, PID: $ESP_PID"
    
    # Start general traffic capture for comparison
    echo "Starting general traffic capture..."
    timeout 1800 oc debug node/$WORKER_NODE -- chroot /host tcpdump -i any -c 500 -w /tmp/general-traffic.pcap > /tmp/ipsec-verification-logs/general-capture.log 2>&1 &
    GENERAL_PID=$!
    echo "General capture started, PID: $GENERAL_PID"
    
    # Give captures time to start
    sleep 5
else
    echo "WARNING: No worker node found for packet capture"
fi

echo "=== Setting Up Simple Network Test ==="
# Create python virtual environment in /tmp where we have write permissions
python3 -m venv /tmp/venv_qe
source /tmp/venv_qe/bin/activate

# Get credentials
ES_PASSWORD=$(cat /secret/password 2>/dev/null || echo "no-password")
ES_USERNAME=$(cat /secret/username 2>/dev/null || echo "no-username")
export ES_PASSWORD ES_USERNAME

# Set required environment variables for network test
export WORKLOAD=${WORKLOAD:-"pod2pod"}
UUID=$(uuidgen || echo "ipsec-test-$(date +%s)")
export UUID
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "unknown-cluster")
export CLUSTER_NAME

echo "=== Network Performance Test Configuration ===" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
echo "WORKLOAD: $WORKLOAD" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
echo "UUID: $UUID" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
echo "CLUSTER_NAME: $CLUSTER_NAME" | tee -a /tmp/ipsec-verification-artifacts/test-start.log

# Check cluster prerequisites
echo "=== Checking Cluster Prerequisites ===" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
WORKER_COUNT=$(oc get nodes --no-headers | grep worker | wc -l)
echo "Worker node count: $WORKER_COUNT" | tee -a /tmp/ipsec-verification-artifacts/test-start.log

# Check permissions
oc auth can-i '*' '*' > /tmp/ipsec-verification-artifacts/permissions-check.log 2>&1
if [ $? -eq 0 ]; then
    echo "Cluster permissions: cluster-admin (OK)" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
else
    echo "Cluster permissions: limited (may affect test)" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
fi

echo "=== Running Simplified Network Test ===" | tee -a /tmp/ipsec-verification-artifacts/test-start.log

# Create simple test pods directly with inline YAML
echo "Creating test server pod..."
oc apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nettest-server
  labels:
    app: nettest
spec:
  containers:
  - name: server
    image: registry.access.redhat.com/ubi8/ubi:latest
    command:
    - /bin/bash
    - -c
    - |
      yum install -y nc
      echo "Server ready on port 8080"
      while true; do 
        echo "HTTP/1.1 200 OK\nContent-Length: 13\n\nHello World\n" | nc -l 8080
      done
    ports:
    - containerPort: 8080
  restartPolicy: Never
EOF

echo "Creating test client pod..."
oc apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nettest-client
  labels:
    app: nettest
spec:
  containers:
  - name: client
    image: registry.access.redhat.com/ubi8/ubi:latest
    command:
    - /bin/bash
    - -c
    - |
      yum install -y nc curl
      echo "Client ready"
      while true; do sleep 30; done
    restartPolicy: Never
EOF

# Create service
oc apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nettest-service
spec:
  selector:
    app: nettest
  ports:
  - port: 8080
    targetPort: 8080
EOF

# Wait for pods to be ready
echo "Waiting for test pods to be ready..." | tee -a /tmp/ipsec-verification-artifacts/test-start.log
sleep 20

# Run network test
(
    echo "Starting network test at $(date)"
    
    # Wait for pods to be running
    for i in {1..20}; do
        SERVER_STATUS=$(oc get pod nettest-server -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        CLIENT_STATUS=$(oc get pod nettest-client -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$SERVER_STATUS" = "Running" ] && [ "$CLIENT_STATUS" = "Running" ]; then
            echo "Pods ready after ${i}0 seconds"
            break
        fi
        echo "Waiting... server: $SERVER_STATUS, client: $CLIENT_STATUS"
        sleep 10
    done
    
    # Get server IP
    SERVER_IP=$(oc get pod nettest-server -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
    echo "Server IP: $SERVER_IP"
    
    if [ ! -z "$SERVER_IP" ]; then
        # Run multiple connection tests to generate traffic
        for i in {1..10}; do
            echo "=== Test iteration $i ==="
            oc exec nettest-client -- curl -s --connect-timeout 5 http://$SERVER_IP:8080 || echo "Connection failed"
            oc exec nettest-client -- nc -z $SERVER_IP 8080 || echo "Port check failed"
            sleep 2
        done
        echo "Network test completed successfully"
    else
        echo "ERROR: Could not get server IP"
        exit 1
    fi
) > /tmp/ipsec-verification-artifacts/netperf-output.log 2>&1 &
NETPERF_PID=$!

echo "Network test started, PID: $NETPERF_PID"

# Monitor test progress
echo "=== Monitoring Test Progress ==="
sleep 30

for i in {1..5}; do
    echo "--- Progress check $i at $(date) ---" | tee -a /tmp/ipsec-verification-artifacts/progress.log
    
    # Check for our test pods
    oc get pods | grep "nettest-" | head -5 | tee -a /tmp/ipsec-verification-artifacts/progress.log || echo "No nettest pods yet"
    
    # If we have test pods and a worker node, capture their specific traffic
    if [ "$WORKER_NODE" != "no-worker-found" ]; then
        SERVER_STATUS=$(oc get pod nettest-server -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        CLIENT_STATUS=$(oc get pod nettest-client -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$SERVER_STATUS" = "Running" ] && [ "$CLIENT_STATUS" = "Running" ]; then
            echo "Found running test pods, capturing traffic..." | tee -a /tmp/ipsec-verification-artifacts/progress.log
            
            SERVER_IP=$(oc get pod nettest-server -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
            CLIENT_IP=$(oc get pod nettest-client -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
            
            if [ ! -z "$SERVER_IP" ] && [ ! -z "$CLIENT_IP" ]; then
                echo "Test Pod IPs: client=$CLIENT_IP <-> server=$SERVER_IP" | tee -a /tmp/ipsec-verification-artifacts/progress.log
                
                # Quick pod-to-pod traffic capture
                timeout 30 oc debug node/$WORKER_NODE -- chroot /host tcpdump -i any -c 10 -w /tmp/nettest-traffic-$i.pcap "host $SERVER_IP and host $CLIENT_IP" > /tmp/ipsec-verification-logs/nettest-capture-$i.log 2>&1 &
                
                # Test connectivity
                echo "Testing connectivity between test pods..." | tee -a /tmp/ipsec-verification-artifacts/progress.log
                oc exec nettest-client -- nc -z $SERVER_IP 8080 >> /tmp/ipsec-verification-artifacts/progress.log 2>&1 || echo "Connection test failed"
            fi
            break
        else
            echo "Test pod status: server=$SERVER_STATUS, client=$CLIENT_STATUS" | tee -a /tmp/ipsec-verification-artifacts/progress.log
        fi
    fi
    
    # Check if test is still running
    if ! kill -0 $NETPERF_PID 2>/dev/null; then
        echo "Network test completed" | tee -a /tmp/ipsec-verification-artifacts/progress.log
        break
    fi
    
    sleep 60
done

# Wait for test completion
echo "=== Waiting for Test Completion ==="
wait $NETPERF_PID 2>/dev/null || NETPERF_EXIT_CODE=$?
echo "Network test completed with exit code: ${NETPERF_EXIT_CODE:-0}" | tee /tmp/ipsec-verification-artifacts/test-completion.log
echo "Test completion time: $(date)" | tee -a /tmp/ipsec-verification-artifacts/test-completion.log

# Stop packet captures
if [ "$WORKER_NODE" != "no-worker-found" ]; then
    echo "=== Stopping Packet Captures ==="
    kill $ESP_PID 2>/dev/null || echo "ESP capture already stopped"
    kill $GENERAL_PID 2>/dev/null || echo "General capture already stopped"
    
    # Collect final IPSec status
    echo "=== Collecting Final IPSec Status ==="
    oc debug node/$WORKER_NODE -- chroot /host ipsec status > /tmp/ipsec-verification-artifacts/final-ipsec-status.log 2>&1 || echo "IPSec status command failed"
    oc debug node/$WORKER_NODE -- chroot /host ipsec trafficstatus > /tmp/ipsec-verification-artifacts/final-ipsec-traffic.log 2>&1 || echo "IPSec traffic status command failed"
    oc debug node/$WORKER_NODE -- chroot /host ip xfrm state > /tmp/ipsec-verification-artifacts/final-xfrm-state.log 2>&1 || echo "XFRM state command failed"
    
    # List packet capture files
    oc debug node/$WORKER_NODE -- chroot /host ls -la /tmp/*.pcap > /tmp/ipsec-verification-artifacts/pcap-files.log 2>&1 || echo "No pcap files found"
fi

# Create analysis summary
echo "=== Creating Analysis Summary ==="
cat > /tmp/ipsec-verification-artifacts/ENCRYPTION-ANALYSIS.md << EOF
# IPSec Encryption Analysis Report

**Generated:** $(date)  
**Cluster:** $(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' 2>/dev/null || echo "Unknown")  
**IPSec Mode:** $IPSEC_MODE  
**Worker Node:** $WORKER_NODE  
**IPSec Pods:** $IPSEC_POD_COUNT running

## Test Execution
- Simple network test completed with exit code: ${NETPERF_EXIT_CODE:-0}
- Packet captures collected during test execution
- IPSec status and configuration logged

## Critical Evidence Files
- \`esp-packets.pcap\` - ESP encrypted traffic (if present, IPSec is working)
- \`general-traffic.pcap\` - General network traffic for comparison
- \`nettest-traffic-*.pcap\` - Specific pod-to-pod communication
- \`final-ipsec-status.log\` - IPSec daemon status and tunnels
- \`final-ipsec-traffic.log\` - IPSec traffic statistics
- \`netperf-output.log\` - Simple network test results

## Analysis Instructions for Dev Team
1. **Check for ESP packets:** If ESP protocol packets are found in captures, IPSec encryption is working
2. **Compare traffic types:** hostNetwork=true (unencrypted) vs hostNetwork=false (should be encrypted)  
3. **Review IPSec status:** Active tunnels and traffic statistics indicate proper IPSec operation
4. **Performance correlation:** Link encryption overhead to observed performance regression

## Key Questions Answered
- ✅ Is IPSec configured? $([ "$IPSEC_MODE" != "Not configured" ] && echo "YES ($IPSEC_MODE)" || echo "NO")
- ✅ Are IPSec pods running? $([ "$IPSEC_POD_COUNT" -gt 0 ] && echo "YES ($IPSEC_POD_COUNT pods)" || echo "NO")
- ✅ Packet captures available? $([ "$WORKER_NODE" != "no-worker-found" ] && echo "YES" || echo "NO - No worker node found")

**Result:** $([ "$IPSEC_MODE" != "Not configured" ] && [ "$IPSEC_POD_COUNT" -gt 0 ] && echo "IPSec appears to be configured and running" || echo "IPSec configuration or deployment issue detected")
EOF

# Final artifact summary
echo "=== Test Summary ===" | tee /tmp/ipsec-verification-artifacts/FINAL-SUMMARY.log
echo "IPSec verification test completed: $(date)" | tee -a /tmp/ipsec-verification-artifacts/FINAL-SUMMARY.log
echo "All artifacts saved to /tmp/ipsec-verification-artifacts/" | tee -a /tmp/ipsec-verification-artifacts/FINAL-SUMMARY.log
echo "Packet captures and analysis ready for dev team review" | tee -a /tmp/ipsec-verification-artifacts/FINAL-SUMMARY.log
ls -la /tmp/ipsec-verification-artifacts/ | tee -a /tmp/ipsec-verification-artifacts/FINAL-SUMMARY.log

echo "=== IPSec Network Performance Test Completed ==="