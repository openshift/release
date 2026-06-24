#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
# Enable debug tracing only when DEBUG=true
${DEBUG:+set -x}


# Convert timeout string (e.g., "30m", "2h") to seconds
timeout_to_seconds() {
  local timeout=${1:-30m}
  local value=${timeout%[mhsd]}
  local unit=${timeout: -1}
  
  case $unit in
    m) echo $((value * 60)) ;;
    h) echo $((value * 3600)) ;;
    s) echo $value ;;
    d) echo $((value * 86400)) ;;
    *) echo 1800 ;;  # Default 30 minutes
  esac
}

echo "========================================"
echo "Starting sos-report collection"
echo "========================================"

# For disconnected or otherwise unreachable environments
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Verify kubeconfig exists
if test ! -f "${KUBECONFIG}"; then
  echo "ERROR: No kubeconfig found, cannot collect sos-report"
  exit 1
fi

# Configuration
SOS_REPORT_DIR="${ARTIFACT_DIR}/sosreports"
SOS_TIMEOUT=${SOS_TIMEOUT:-"30m"}
SOS_NODE_SELECTOR=${SOS_NODE_SELECTOR:-"node-role.kubernetes.io/worker="}
SOS_MAX_PARALLEL=${SOS_MAX_PARALLEL:-"10"}
SOS_COLLECT_ALL_NODES=${SOS_COLLECT_ALL_NODES:-"false"}
SOS_PLUGIN_FILTER=${SOS_PLUGIN_FILTER:-"ovs,openvswitch,ovn,networking,process,systemd,cgroups"}

# Create output directory
mkdir -p "${SOS_REPORT_DIR}"

echo "Configuration:"
echo "  SOS_TIMEOUT: ${SOS_TIMEOUT}"
echo "  SOS_NODE_SELECTOR: ${SOS_NODE_SELECTOR}"
echo "  SOS_MAX_PARALLEL: ${SOS_MAX_PARALLEL}"
echo "  SOS_COLLECT_ALL_NODES: ${SOS_COLLECT_ALL_NODES}"
echo "  SOS_PLUGIN_FILTER: ${SOS_PLUGIN_FILTER}"

# Function to collect sos-report from a single node
collect_sosreport_from_node() {
  local node_name=$1
  local output_dir=$2

  echo "Collecting sos-report from node: ${node_name}"

  # Create a debug pod on the target node
  local pod_name
  pod_name="sosreport-${node_name}-$(date +%s)"

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: default
spec:
  hostNetwork: true
  hostPID: true
  hostIPC: true
  nodeName: ${node_name}
  containers:
  - name: sosreport
    image: registry.redhat.io/rhel8/support-tools:latest
    command:
    - /bin/bash
    - -c
    - |
      set -x
      # Install sos if not present
      if ! command -v sos &> /dev/null; then
        yum install -y sos || dnf install -y sos
      fi

      # Run sos-report with filtered plugins
      sos report --batch \
        --tmp-dir /host/tmp \
        --only-plugins=${SOS_PLUGIN_FILTER} \
        --all-logs \
        --log-size=100 \
        --since=24hours \
        || true

      # Keep container alive for file copy
      sleep 3600
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
    - name: host-tmp
      mountPath: /host/tmp
  volumes:
  - name: host
    hostPath:
      path: /
  - name: host-tmp
    hostPath:
      path: /tmp
  restartPolicy: Never
  tolerations:
  - operator: Exists
EOF

  # Wait for pod to be running
  echo "Waiting for sosreport pod to be ready..."
  oc wait --for=condition=Ready pod/${pod_name} --timeout=${SOS_TIMEOUT} -n default || {
    echo "ERROR: Pod ${pod_name} failed to become ready"
    oc delete pod ${pod_name} -n default --grace-period=0 --force || true
    return 1
  }

  # Wait for sos-report to complete (check for sosreport*.tar.xz files)
  echo "Waiting for sos-report generation to complete..."
  local max_wait
  max_wait=$(timeout_to_seconds "${SOS_TIMEOUT:-30m}")
  local elapsed=0
  local interval=30

  while [ $elapsed -lt $max_wait ]; do
    # Check if sos-report file exists
    local sosreport_count
    sosreport_count=$(oc exec -n default ${pod_name} -- bash -c \
      "find /host/tmp -name 'sosreport-*.tar.xz' 2>/dev/null | wc -l" || echo "0")

    if [ "$sosreport_count" -gt 0 ]; then
      echo "sos-report generation completed"
      break
    fi

    echo "Waiting for sos-report generation... (${elapsed}s / ${max_wait}s)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  if [ $elapsed -ge $max_wait ]; then
    echo "WARNING: sos-report generation timed out for node ${node_name}"
  fi

  # Copy sos-report files from pod to artifact directory
  echo "Copying sos-report from pod to artifacts..."
  oc exec -n default ${pod_name} -- bash -c \
    "find /host/tmp -name 'sosreport-*.tar.xz' -type f" | while read sosfile; do
    local basename
    basename=$(basename "$sosfile")
    echo "  Copying: $sosfile -> ${output_dir}/${node_name}-${basename}"
    oc cp -n default ${pod_name}:${sosfile} "${output_dir}/${node_name}-${basename}" || {
      echo "WARNING: Failed to copy ${sosfile}"
    }
  done

  # Cleanup pod
  echo "Cleaning up sosreport pod..."
  oc delete pod ${pod_name} -n default --grace-period=30 || true

  echo "sos-report collection completed for node: ${node_name}"
}

# Export function for parallel execution
export -f collect_sosreport_from_node
export KUBECONFIG SOS_REPORT_DIR SOS_TIMEOUT SOS_PLUGIN_FILTER

# Get list of nodes to collect from
if [ "${SOS_COLLECT_ALL_NODES}" == "true" ]; then
  echo "Collecting sos-report from ALL nodes"
  node_list=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
else
  echo "Collecting sos-report from nodes matching: ${SOS_NODE_SELECTOR}"
  node_list=$(oc get nodes -l "${SOS_NODE_SELECTOR}" -o jsonpath='{.items[*].metadata.name}')
fi

if [ -z "$node_list" ]; then
  echo "ERROR: No nodes found matching selector: ${SOS_NODE_SELECTOR}"
  exit 1
fi

echo "Nodes to collect from: $node_list"
node_count=$(echo $node_list | wc -w)
echo "Total nodes: $node_count"

# Collect sos-reports in parallel (with max parallel limit)
echo "========================================"
echo "Starting parallel sos-report collection"
echo "========================================"

echo "$node_list" | tr ' ' '\n' | xargs -P ${SOS_MAX_PARALLEL} -I {} bash -c \
  'collect_sosreport_from_node "{}" "${SOS_REPORT_DIR}"'

# Summary
echo "========================================"
echo "sos-report Collection Summary"
echo "========================================"
collected_count=$(find "${SOS_REPORT_DIR}" -name "*.tar.xz" | wc -l)
echo "Total sos-reports collected: ${collected_count} / ${node_count}"

if [ ${collected_count} -eq 0 ]; then
  echo "ERROR: No sos-reports were collected"
  exit 1
fi

# List collected files
echo ""
echo "Collected sos-reports:"
find "${SOS_REPORT_DIR}" -name "*.tar.xz" -exec ls -lh {} \;

# Extract key information from sos-reports for quick analysis
echo ""
echo "Extracting key OVS/OVN information from sos-reports..."
for sosfile in "${SOS_REPORT_DIR}"/*.tar.xz; do
  if [ -f "$sosfile" ]; then
    echo ""
    echo "Processing: $(basename $sosfile)"
    tar -xJf "$sosfile" -C /tmp/

    # Extract OVS process info
    extracted_dir=$(tar -tJf "$sosfile" | head -1 | cut -d/ -f1)
    if [ -d "/tmp/${extracted_dir}" ]; then
      # Look for OVS process information
      if [ -f "/tmp/${extracted_dir}/sos_commands/process/ps_auxwww" ]; then
        echo "  OVS Processes:"
        grep -E "ovs-vswitchd|ovsdb-server" "/tmp/${extracted_dir}/sos_commands/process/ps_auxwww" || echo "    No OVS processes found"
      fi

      # Look for systemd OVS services
      if [ -d "/tmp/${extracted_dir}/sos_commands/systemd" ]; then
        echo "  OVS Services:"
        find "/tmp/${extracted_dir}/sos_commands/systemd" -name "*ovs*.service" -type f | while read svcfile; do
          echo "    $(basename $svcfile)"
        done
      fi

      # Cleanup extracted files
      rm -rf "/tmp/${extracted_dir}"
    fi
  fi
done

echo ""
echo "========================================"
echo "sos-report collection completed successfully"
echo "========================================"

exit 0
