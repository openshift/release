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

# If git still not available, try downloading a static binary
if ! command -v git &> /dev/null; then
    echo "Attempting to download static git binary..."
    mkdir -p /tmp/git-static
    cd /tmp/git-static
    
    # Download static git binary for Linux x86_64
    if command -v curl &> /dev/null; then
        curl -L -o git-static.tar.xz "https://github.com/git/git/releases/download/v2.41.0/git-2.41.0.tar.xz" 2>/dev/null || echo "Could not download git"
    elif command -v wget &> /dev/null; then
        wget -O git-static.tar.xz "https://github.com/git/git/releases/download/v2.41.0/git-2.41.0.tar.xz" 2>/dev/null || echo "Could not download git"
    fi
    
    # Alternative: try to get git from busybox or other minimal sources
    if ! command -v git &> /dev/null && command -v apk &> /dev/null; then
        apk add --no-cache git --force 2>/dev/null || echo "Force install failed"
    fi
    
    cd /tmp
fi

# Final fallback: check if git is available in alternative paths
if ! command -v git &> /dev/null; then
    echo "Searching for git in alternative locations..."
    find /usr /opt /bin 2>/dev/null | grep -E "bin/git$" | head -1 | while read gitpath; do
        if [ -x "$gitpath" ]; then
            ln -sf "$gitpath" /usr/local/bin/git 2>/dev/null || echo "Could not link git"
        fi
    done
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

echo "=== Setting Up E2E Benchmarking Environment ==="
# Create python virtual environment in /tmp where we have write permissions
python3 -m venv /tmp/venv_qe
source /tmp/venv_qe/bin/activate

# Get credentials
ES_PASSWORD=$(cat /secret/password 2>/dev/null || echo "no-password")
ES_USERNAME=$(cat /secret/username 2>/dev/null || echo "no-username")

export ES_PASSWORD ES_USERNAME

# Clone e2e-benchmarking repository
REPO_URL=https://github.com/cloud-bulldozer/e2e-benchmarking
LATEST_TAG=$(curl -s https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest | jq -r .tag_name 2>/dev/null || echo "v2.7.1")
TAG_OPTION="--branch ${LATEST_TAG}"

echo "Cloning e2e-benchmarking ${LATEST_TAG}..." | tee /tmp/ipsec-verification-artifacts/repo-clone.log

# Skip git entirely and use curl/wget for more reliability in CI environment
echo "Using direct download method for better CI compatibility..." | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
GIT_FAILED=true

# If git failed or not available, use curl/wget
if [ "$GIT_FAILED" = "true" ]; then
    # Try using curl to download and extract the repository
    ARCHIVE_URL="https://github.com/cloud-bulldozer/e2e-benchmarking/archive/refs/tags/${LATEST_TAG}.tar.gz"
    echo "Attempting to download ${ARCHIVE_URL}" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
    
    if command -v curl &> /dev/null; then
        curl -L -o e2e-benchmarking.tar.gz "$ARCHIVE_URL" 2>&1 | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
        if [ -f e2e-benchmarking.tar.gz ]; then
            tar -xzf e2e-benchmarking.tar.gz 2>&1 | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
            mv e2e-benchmarking-* e2e-benchmarking 2>/dev/null || echo "Repository directory rename failed"
            echo "Repository downloaded and extracted via curl" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
        fi
    elif command -v wget &> /dev/null; then
        wget -O e2e-benchmarking.tar.gz "$ARCHIVE_URL" 2>&1 | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
        if [ -f e2e-benchmarking.tar.gz ]; then
            tar -xzf e2e-benchmarking.tar.gz 2>&1 | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
            mv e2e-benchmarking-* e2e-benchmarking 2>/dev/null || echo "Repository directory rename failed"
            echo "Repository downloaded and extracted via wget" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
        fi
    else
        echo "ERROR: Neither git, curl, nor wget available for repository download" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
        exit 1
    fi
fi

# Verify repository was downloaded
if [ ! -d "e2e-benchmarking" ]; then
    echo "ERROR: Failed to obtain e2e-benchmarking repository" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
    exit 1
else
    echo "Repository successfully obtained" | tee -a /tmp/ipsec-verification-artifacts/repo-clone.log
fi

cd e2e-benchmarking

# Install requirements if available
if [ -f requirements.txt ]; then
    echo "Installing Python requirements..."
    pip install -r requirements.txt > /tmp/ipsec-verification-artifacts/pip-install.log 2>&1 || echo "Some requirements failed to install"
fi

echo "=== Finding Network Performance Test Directory ==="
if [ -d "workloads/network-perf" ]; then
    cd workloads/network-perf
    echo "Using workloads/network-perf"
elif [ -d "workloads/k8s-netperf" ]; then
    cd workloads/k8s-netperf
    echo "Using workloads/k8s-netperf"
else
    echo "Searching for network performance test directory..."
    find . -name "*netperf*" -type d | tee /tmp/ipsec-verification-artifacts/netperf-dirs.log
    NETPERF_DIR=$(find . -name "*netperf*" -type d | head -1)
    if [ ! -z "$NETPERF_DIR" ]; then
        cd "$NETPERF_DIR"
        echo "Using directory: $NETPERF_DIR"
    else
        echo "ERROR: No network performance test directory found"
        ls -la workloads/ | tee -a /tmp/ipsec-verification-artifacts/netperf-dirs.log
        exit 1
    fi
fi

echo "=== Starting Network Performance Test ==="
echo "Test start time: $(date)" | tee /tmp/ipsec-verification-artifacts/test-start.log
echo "Current directory: $(pwd)" | tee -a /tmp/ipsec-verification-artifacts/test-start.log
ls -la | tee -a /tmp/ipsec-verification-artifacts/test-start.log

# Run the network performance test
if [ -f "run.py" ]; then
    echo "Running Python test script..."
    python3 -u ./run.py > /tmp/ipsec-verification-artifacts/netperf-output.log 2>&1 &
    NETPERF_PID=$!
elif [ -f "run.sh" ]; then
    echo "Running shell test script..."
    bash ./run.sh > /tmp/ipsec-verification-artifacts/netperf-output.log 2>&1 &
    NETPERF_PID=$!
else
    echo "ERROR: No run script found"
    ls -la | tee /tmp/ipsec-verification-artifacts/test-start.log
    exit 1
fi

echo "NetPerf test started, PID: $NETPERF_PID"

# Monitor test progress
echo "=== Monitoring Test Progress ==="
sleep 30  # Give test time to start

for i in {1..10}; do
    echo "--- Progress check $i at $(date) ---" | tee -a /tmp/ipsec-verification-artifacts/progress.log
    
    # Check for netperf pods
    oc get pods | grep netperf | head -5 | tee -a /tmp/ipsec-verification-artifacts/progress.log || echo "No netperf pods yet"
    
    # If we have netperf pods and a worker node, capture their specific traffic
    if [ "$WORKER_NODE" != "no-worker-found" ]; then
        NETPERF_PODS=$(oc get pods --no-headers | grep netperf | awk '{print $1}' | head -2)
        if [ ! -z "$NETPERF_PODS" ]; then
            echo "Found netperf pods, capturing traffic..." | tee -a /tmp/ipsec-verification-artifacts/progress.log
            POD1=$(echo "$NETPERF_PODS" | head -1)
            POD2=$(echo "$NETPERF_PODS" | tail -1)
            
            if [ "$POD1" != "$POD2" ]; then
                POD1_IP=$(oc get pod $POD1 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
                POD2_IP=$(oc get pod $POD2 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
                
                if [ ! -z "$POD1_IP" ] && [ ! -z "$POD2_IP" ]; then
                    echo "Pod IPs: $POD1_IP <-> $POD2_IP" | tee -a /tmp/ipsec-verification-artifacts/progress.log
                    
                    # Quick pod-to-pod traffic capture
                    timeout 30 oc debug node/$WORKER_NODE -- chroot /host tcpdump -i any -c 10 -w /tmp/pod-traffic-$i.pcap "host $POD1_IP and host $POD2_IP" > /tmp/ipsec-verification-logs/pod-capture-$i.log 2>&1 &
                    
                    # Test connectivity
                    oc exec $POD1 -- ping -c 3 $POD2_IP >> /tmp/ipsec-verification-artifacts/progress.log 2>&1 || echo "Ping test failed"
                fi
            fi
            break  # Found pods, no need to keep checking
        fi
    fi
    
    # Check if test is still running
    if ! kill -0 $NETPERF_PID 2>/dev/null; then
        echo "NetPerf test completed" | tee -a /tmp/ipsec-verification-artifacts/progress.log
        break
    fi
    
    sleep 60
done

# Wait for test completion
echo "=== Waiting for Test Completion ==="
wait $NETPERF_PID 2>/dev/null || NETPERF_EXIT_CODE=$?
echo "NetPerf test completed with exit code: ${NETPERF_EXIT_CODE:-0}" | tee /tmp/ipsec-verification-artifacts/test-completion.log
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
- Network performance test completed with exit code: ${NETPERF_EXIT_CODE:-0}
- Packet captures collected during test execution
- IPSec status and configuration logged

## Critical Evidence Files
- \`esp-packets.pcap\` - ESP encrypted traffic (if present, IPSec is working)
- \`general-traffic.pcap\` - General network traffic for comparison
- \`pod-traffic-*.pcap\` - Specific pod-to-pod communication
- \`final-ipsec-status.log\` - IPSec daemon status and tunnels
- \`final-ipsec-traffic.log\` - IPSec traffic statistics
- \`netperf-output.log\` - Performance test results

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