#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# 1. Setup environment variables for the deployment script
export SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL}"
export NAMESPACE=tls-scanner-test

# Manually apply nftables rules to all nodes to allow traffic on scanner ports
# This is necessary because we are using a pre-provisioned cluster (cluster_claim)
# and standard provision-time firewall overrides (EXTRA_NFTABLES_MASTER_FILE) do not apply.
echo "--- Applying firewall rules to nodes ---"
# Get all nodes (masters and workers)
NODES=$(oc get nodes -o name)
for node in $NODES; do
  echo "Updating firewall on $node..."
  # Use oc debug to run commands on the node host
  # We try both nft and iptables to cover different OS versions (RHEL8 vs RHEL9)
  oc debug "$node" -- image=image-registry.openshift-image-registry.svc:5000/openshift/tools:latest -- chroot /host bash -c "
    echo 'Applying rules...'
    # Ports: 8443, 2379, 10300, 10901, 29108 (TCP/UDP)
    ports=(8443 2379 10300 10901 29108)
    for port in \"\${ports[@]}\"; do
        # Try nftables (RHEL9+)
        if command -v nft >/dev/null 2>&1; then
            nft add rule inet filter input tcp dport \$port accept || true
            nft add rule inet filter input udp dport \$port accept || true
        fi
        # Try iptables (RHEL8/Legacy) - using -I to insert at top
        if command -v iptables >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport \$port -j ACCEPT || true
            iptables -I INPUT -p udp --dport \$port -j ACCEPT || true
        fi
    done
    echo 'Rules applied.'
  " 2>/dev/null || echo "Failed to update $node"
done
echo "--- Firewall update complete ---"

oc create namespace "${NAMESPACE}"

# Use a trap to ensure cleanup happens even if there are errors.
trap './deploy.sh cleanup' EXIT

# 2. Deploy the scanner Job to the ephemeral cluster
./deploy.sh deploy

# 3. Add immediate debugging to check the state of the Job right after creation.
echo "--- Checking Job status immediately after deployment ---"
sleep 5 # Give the controllers a moment to react.
oc describe job "tls-scanner-job" -n "${NAMESPACE}" || echo "Job description not available."
echo "--- Checking for events in the namespace ---"
oc get events -n "${NAMESPACE}" --sort-by='.metadata.creationTimestamp'
echo "--- End of immediate debug ---"

# Start a background monitor to log status every 15 minutes
(
  while true; do
    sleep 900
    echo "--- Monitor [$(date)] ---"
    echo "Job Status:"
    oc get job "tls-scanner-job" -n "${NAMESPACE}" -o wide || echo "Job not found"
    echo "Pod Status:"
    oc get pods -n "${NAMESPACE}" -l job-name=tls-scanner-job -o wide || echo "No pods found"
    echo "-------------------------"
  done
) &
MONITOR_PID=$!

# 4. Stream logs and wait for completion
echo "Waiting for tls-scanner-job to complete in namespace ${NAMESPACE}..."

# Get the pod name (retry a few times if not immediately available)
for i in {1..5}; do
  POD_NAME=$(oc get pods -n "${NAMESPACE}" -l job-name=tls-scanner-job -o jsonpath='{.items[0].metadata.name}')
  if [ -n "${POD_NAME}" ]; then
    break
  fi
  sleep 2
done

if [ -z "${POD_NAME}" ]; then
  echo "Error: Could not find a pod for the job."
  oc describe job "tls-scanner-job" -n "${NAMESPACE}"
  exit 1
fi

echo "Found pod: ${POD_NAME}"

# Describe the pod immediately to catch early issues
echo "--- Describing scanner pod for more details ---"
oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
echo "--- End of pod description ---"

# Wait for pod to actually start running (not just exist)
echo "Waiting for pod to start running..."
POD_RUNNING=false
for i in {1..60}; do  # Wait up to 10 minutes for pod to start
  POD_PHASE=$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "$POD_PHASE" = "Running" ]; then
    echo "Pod is now running."
    POD_RUNNING=true
    break
  elif [ "$POD_PHASE" = "Failed" ]; then
    echo "ERROR: Pod failed. Phase: $POD_PHASE"
    echo "=== Container Logs (current) ==="
    oc logs "${POD_NAME}" -n "${NAMESPACE}" --all-containers=true 2>&1 || echo "No current logs available"
    echo "=== Container Logs (previous/terminated) ==="
    oc logs "${POD_NAME}" -n "${NAMESPACE}" --all-containers=true --previous 2>&1 || echo "No previous logs available"
    echo "=== End Container Logs ==="
    echo "=== Pod Description ==="
    oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
    echo "=== Namespace Events ==="
    oc get events -n "${NAMESPACE}" --sort-by='.metadata.creationTimestamp'
    kill $MONITOR_PID || true
    exit 1
  elif [ "$POD_PHASE" = "Unknown" ]; then
    echo "ERROR: Pod phase is Unknown"
    oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
    oc get events -n "${NAMESPACE}" --sort-by='.metadata.creationTimestamp'
    kill $MONITOR_PID || true
    exit 1
  fi
  echo "Pod status: $POD_PHASE. Waiting... ($i/60)"
  sleep 10
done

if [ "$POD_RUNNING" = "false" ]; then
  echo "Error: Pod did not start running within 10 minutes"
  echo "=== Final Pod Status ==="
  oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o yaml
  echo "=== Pod Description ==="
  oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
  echo "=== Namespace Events ==="
  oc get events -n "${NAMESPACE}" --sort-by='.metadata.creationTimestamp'
  kill $MONITOR_PID || true
  exit 1
fi

# Start streaming logs immediately in the background.
# We use a loop to retry 'oc logs' if it fails initially (e.g. container creating)
echo "--- Start of Scanner Logs ---"
(
  retries=0
  while [ $retries -lt 20 ]; do
    if oc logs -f "pod/${POD_NAME}" -n "${NAMESPACE}"; then
      # If oc logs returns 0, it means it streamed successfully and finished.
      exit 0
    else
      # If it returns non-zero, it failed to attach or stream.
      echo "Log streaming interrupted or failed to start. Retrying in 10s..."
      sleep 10
      retries=$((retries+1))
    fi
  done
  echo "Gave up streaming logs after multiple retries."
) &
LOG_PID=$!

# Monitor logs for completion signal "Pausing for log collection..." to trigger artifact copy
# This ensures we copy artifacts while the pod is still running (during its 120s sleep)
echo "Monitoring logs for scanner completion..."
SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"
mkdir -p "${SCANNER_ARTIFACT_DIR}"

# Create run_info.json for downstream tools
cat <<EOF > "${SCANNER_ARTIFACT_DIR}/run_info.json"
{
  "pr_number": "${PULL_NUMBER:-}",
  "job_name": "${JOB_NAME:-}",
  "prow_job_id": "${PROW_JOB_ID:-}",
  "run_date": "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

start_wait=$(date +%s)
while true; do
    current_time=$(date +%s)
    if [ $((current_time - start_wait)) -gt 12600 ]; then # 3.5h timeout
        echo "Timeout waiting for scanner completion."
        exit 1
    fi

    # Check for the specific log message indicating scanner finished
    if oc logs "${POD_NAME}" -n "${NAMESPACE}" 2>&1 | grep -q "Pausing for log collection"; then
         echo "Scanner finished (detected via logs). Copying artifacts..."
         
         # Try to copy artifacts
         if oc cp "${NAMESPACE}/${POD_NAME}:/artifacts/." "${SCANNER_ARTIFACT_DIR}/"; then
            echo "Artifacts copied successfully."
         else
            echo "Warning: Failed to copy artifacts despite scanner being in pause mode."
         fi
         break
    fi

    # Check if job failed
    if oc get job "tls-scanner-job" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' | grep -q "True"; then
         echo "Job failed."
         exit 1
    fi
    
    # Check if job completed (we might have missed the window)
    if oc get job "tls-scanner-job" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q "True"; then
         echo "Job completed before we could detect pause message."
         break
    fi

    sleep 10
done

# Wait for the job to complete (it should be finishing soon if not already)
if ! oc wait --for=condition=complete "job/tls-scanner-job" -n "${NAMESPACE}" --timeout=3h30m; then
  echo "Job did not complete in time (3h30m timeout)."
  echo "--- End of Scanner Logs (Timeout) ---"
  
  echo "--- Debugging Timeout ---"
  echo "1. Describing Job:"
  oc describe job "tls-scanner-job" -n "${NAMESPACE}"
  
  echo "2. Listing all Pods for the Job:"
  oc get pods -n "${NAMESPACE}" -l job-name=tls-scanner-job -o wide
  
  echo "3. Describing Current Pods:"
  # Describe all pods currently associated with the job
  oc describe pods -n "${NAMESPACE}" -l job-name=tls-scanner-job

  echo "4. Namespace Events:"
  oc get events -n "${NAMESPACE}" --sort-by='.metadata.creationTimestamp'
  
  echo "--- End Debugging Timeout ---"

  # Kill the log streamer and monitor
  kill $LOG_PID || true
  kill $MONITOR_PID || true
  exit 1
fi

echo "Job completed successfully."

# Wait for the log streamer to finish (it should exit when the pod terminates)
wait $LOG_PID || true
# Kill monitor
kill $MONITOR_PID || true
echo "--- End of Scanner Logs ---"

echo "Scan complete. Artifacts collected in ${SCANNER_ARTIFACT_DIR}."
# The 'trap' will execute ./deploy.sh cleanup on exit.


