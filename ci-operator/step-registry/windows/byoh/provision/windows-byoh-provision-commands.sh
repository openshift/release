#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

umask 077

WMCO_NAMESPACE="openshift-windows-machine-config-operator"
DIAGNOSTIC_TIMEOUT="${DIAGNOSTIC_TIMEOUT:-30s}"
DIAGNOSTIC_KILL_AFTER="${DIAGNOSTIC_KILL_AFTER:-5s}"
DIAGNOSTIC_MAX_LINES=500
BYOH_PROVISIONER_DIR="${BYOH_PROVISIONER_DIR:-/usr/local/share/byoh-provisioner}"

# Track background collector PIDs for cleanup on all exit paths
NODE_WATCHER_PID=""
CCM_WATCHER_PID=""

# Redaction pattern: strip IPv4/IPv6 addresses, AWS account IDs (12-digit), ARNs,
# internal FQDNs (*.internal, *.compute.amazonaws.com), and tokens/keys.
# Timestamps (HH:MM:SS) are temporarily protected to avoid IPv6 false-positives.
# Applied to all public artifact output.
REDACT_PATTERN='s/([0-2][0-9]):([0-5][0-9]):([0-5][0-9])/_TS_\1_\2_\3_TS_/g; s/[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){2,7}/<REDACTED-IPv6>/g; s/(^|[^0-9a-fA-F:])::([0-9a-fA-F]{1,4})(:[0-9a-fA-F]{0,4}){0,6}/\1<REDACTED-IPv6>/g; s/::<REDACTED-IPv6>/<REDACTED-IPv6>/g; s/_TS_([0-2][0-9])_([0-5][0-9])_([0-5][0-9])_TS_/\1:\2:\3/g; s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[REDACTED-IP]/g; s/arn:aws:[a-zA-Z0-9_-]*:[a-z0-9-]*:[0-9]{12}:[^ "]*/<REDACTED-ARN>/g; s/[0-9]{12}/<REDACTED-ACCOUNT>/g; s/[a-z0-9-]+\.(internal|compute\.amazonaws\.com|ec2\.internal)/<REDACTED-FQDN>/g; s/(password|token|secret|key|credential)[=: ]+[^ "]+/\1=<REDACTED>/gi'

redact_text() {
    sed -E "${REDACT_PATTERN}"
}

archive_terraform_state() {
    local archive archive_tmp platform source_dir
    local found=false
    local failed=false

    echo "Saving Terraform cleanup state to protected shared storage..."
    for platform in aws azure gcp vsphere nutanix none; do
        source_dir="${BYOH_TMP_DIR}${platform}"
        [[ -d "${source_dir}" ]] || continue
        found=true
        archive="${SHARED_DIR}/terraform_byoh_${platform}.tar"
        archive_tmp="${archive}.tmp"
        if tar -cf "${archive_tmp}" -C "${source_dir}" --exclude='.terraform' . &&
            chmod 600 "${archive_tmp}" &&
            mv -f "${archive_tmp}" "${archive}"; then
            echo "Terraform cleanup state saved for platform ${platform}"
        else
            failed=true
            rm -f "${archive_tmp}" || true
            echo "WARNING: Failed to save Terraform cleanup state for platform ${platform}"
        fi
    done

    if [[ "${found}" != "true" ]]; then
        echo "WARNING: No Terraform platform directory found in protected shared storage"
        return 1
    fi
    [[ "${failed}" != "true" ]]
}

capture_diagnostic() {
    local name="$1"
    shift
    local diagnostic_output
    local output_dir="${ARTIFACT_DIR:-/tmp}/wmco-provision-failure"
    local output_file="${output_dir}/${name}.txt"

    if ! mkdir -p "${output_dir}"; then
        echo "WARNING: Could not create failure diagnostic directory: ${output_dir}"
        return 0
    fi
    diagnostic_output=$({
        echo "Command: $*"
        if ! timeout --kill-after="${DIAGNOSTIC_KILL_AFTER}" "${DIAGNOSTIC_TIMEOUT}" "$@" 2>&1 | tail -n "${DIAGNOSTIC_MAX_LINES}"; then
            echo "Diagnostic command failed or exceeded ${DIAGNOSTIC_TIMEOUT}"
        fi
    } | redact_text)
    if printf '%s\n' "${diagnostic_output}" >"${output_file}"; then
        echo "Saved failure diagnostic: ${output_file}"
    else
        echo "WARNING: Could not write failure diagnostic: ${output_file}"
    fi
}

collect_failure_diagnostics() {
    echo "Collecting bounded WMCO failure diagnostics (best effort)..."
    # Sanitized technical summaries only — no raw IPs, hostnames, or identifiers
    # in public artifacts. Custom columns avoid wide output that leaks node addresses.
    capture_diagnostic wmco-workloads \
        oc get deployments,pods -n "${WMCO_NAMESPACE}" \
        -o 'custom-columns=KIND:.kind,NAME:.metadata.name,READY:.status.readyReplicas,PHASE:.status.phase'
    capture_diagnostic wmco-status \
        oc get csv,subscription -n "${WMCO_NAMESPACE}"
    capture_diagnostic wmco-events \
        oc get events -n "${WMCO_NAMESPACE}" --sort-by=.lastTimestamp \
        -o 'custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message,COUNT:.count,LAST:.lastTimestamp'
    capture_diagnostic certificate-signing-requests \
        oc get csr -o 'custom-columns=NAME:.metadata.name,SIGNER:.spec.signerName,CONDITION:.status.conditions[0].type'
    capture_diagnostic windows-node-summary \
        oc get nodes -l kubernetes.io/os=windows \
        -o 'custom-columns=READY:.status.conditions[?(@.type=="Ready")].status,READY_REASON:.status.conditions[?(@.type=="Ready")].reason,OS_IMAGE:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion'

    # Raw WMCO logs go to protected SHARED_DIR only (not public ARTIFACT_DIR)
    if [[ -d "${SHARED_DIR}" ]]; then
        local raw_log_file="${SHARED_DIR}/wmco-failure-logs.txt"
        {
            echo "WMCO operator logs (raw, protected)"
            timeout --kill-after="${DIAGNOSTIC_KILL_AFTER}" "${DIAGNOSTIC_TIMEOUT}" \
                oc logs deployment/windows-machine-config-operator -n "${WMCO_NAMESPACE}" \
                --all-containers=true --prefix=true --since=30m --tail=500 2>&1 || true
        } >"${raw_log_file}" 2>&1 || true
        chmod 600 "${raw_log_file}" 2>/dev/null || true
    fi
    echo "WMCO failure diagnostic collection finished"
}

# --- Early node and CCM watcher ---
# Captures Windows Node metadata and AWS cloud-controller-manager (CCM) state
# BEFORE BYOH registration triggers WMCO. This is read-only observation that
# does not modify any cluster resources.
start_node_watcher() {
    local output_dir="${SHARED_DIR}/early-node-capture"
    mkdir -p "${output_dir}" || return 0

    (
        _watch_pid=""
        trap '
            [[ -n "${_watch_pid}" ]] && kill -TERM "${_watch_pid}" 2>/dev/null || true
            wait "${_watch_pid}" 2>/dev/null || true
            exit 0
        ' TERM
        # Watch mode (--watch) streams node events in real-time, reliably
        # capturing nodes that may exist for only 1-5 seconds. Polling at 15s
        # had a 7-33% chance per poll of catching fleeting nodes.
        # Output goes to SHARED_DIR (protected); child PID tracked for clean
        # TERM cleanup (no kill 0).
        timeout 900 oc get nodes -l kubernetes.io/os=windows --watch \
            -o jsonpath='{.metadata.name} providerID={.spec.providerID} addressTypes={range .status.addresses[*]}{.type},{end} osImage={.status.nodeInfo.osImage} kubelet={.status.nodeInfo.kubeletVersion}{"\n"}' \
            >>"${output_dir}/node-snapshots.txt" 2>/dev/null &
        _watch_pid=$!
        wait "${_watch_pid}" 2>/dev/null || true
        _watch_pid=""
    ) &
    NODE_WATCHER_PID=$!
    echo "Started early node watcher (PID ${NODE_WATCHER_PID})"
}

start_ccm_watcher() {
    local output_dir="${SHARED_DIR}/early-node-capture"
    mkdir -p "${output_dir}" || return 0

    (
        _ccm_child_pid=""
        trap '
            [[ -n "${_ccm_child_pid}" ]] && kill -TERM "${_ccm_child_pid}" 2>/dev/null || true
            wait "${_ccm_child_pid}" 2>/dev/null || true
            exit 0
        ' TERM
        # Discover the actual cloud-controller-manager workload.
        # On OpenShift the CCM typically runs in openshift-cloud-controller-manager
        # namespace as a deployment named cloud-controller-manager.
        local ccm_ns="" ccm_deploy=""
        for ns in openshift-cloud-controller-manager kube-system; do
            if oc get namespace "${ns}" &>/dev/null; then
                local deploy
                deploy=$(oc get deployments -n "${ns}" --no-headers 2>/dev/null \
                    | awk '/cloud-controller/ {print $1; exit}') || true
                if [[ -n "${deploy}" ]]; then
                    ccm_ns="${ns}"
                    ccm_deploy="${deploy}"
                    break
                fi
            fi
        done

        if [[ -z "${ccm_ns}" || -z "${ccm_deploy}" ]]; then
            echo "No cloud-controller-manager deployment found; skipping CCM capture" \
                >"${output_dir}/ccm-status.txt" 2>/dev/null || true
            exit 0
        fi

        echo "Discovered CCM: namespace=${ccm_ns} deployment=${ccm_deploy}" \
            >"${output_dir}/ccm-status.txt" 2>/dev/null || true

        # Capture CCM deployment status (sanitized for public use)
        oc get deployment "${ccm_deploy}" -n "${ccm_ns}" \
            -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.status.replicas,AVAILABLE:.status.availableReplicas' \
            >>"${output_dir}/ccm-status.txt" 2>/dev/null || true

        # Stream CCM logs to protected storage only (may contain IPs/identifiers).
        # Run in background with tracked PID so TERM cleanup kills only this
        # owned child — not the caller or process group (never use kill 0).
        timeout 900 oc logs "deployment/${ccm_deploy}" -n "${ccm_ns}" \
            --all-containers=true --prefix=true --since=30m --tail=1000 -f \
            >"${output_dir}/ccm-logs-raw.txt" 2>&1 &
        _ccm_child_pid=$!
        wait "${_ccm_child_pid}" 2>/dev/null || true
        _ccm_child_pid=""
        chmod 600 "${output_dir}/ccm-logs-raw.txt" 2>/dev/null || true
    ) &
    CCM_WATCHER_PID=$!
    echo "Started early CCM watcher (PID ${CCM_WATCHER_PID})"
}

stop_watchers() {
    local pid
    for pid in ${NODE_WATCHER_PID} ${CCM_WATCHER_PID}; do
        [[ -z "${pid}" ]] && continue
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            # Bounded wait for clean shutdown (max 5 seconds per watcher)
            local i=0
            while (( i < 50 )) && kill -0 "${pid}" 2>/dev/null; do
                sleep 0.1
                (( i++ ))
            done
            # Force kill if still alive
            kill -KILL "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    NODE_WATCHER_PID=""
    CCM_WATCHER_PID=""
}

handle_exit() {
    local status=$?
    trap - EXIT
    set +o errexit
    # Always stop background watchers on every exit path
    stop_watchers
    if (( status != 0 )); then
        echo "Windows BYOH provisioning failed with exit status ${status}"
        archive_terraform_state || true
        collect_failure_diagnostics || true
        echo "Returning original provisioning exit status ${status}"
    fi
    exit "${status}"
}

echo "=== Windows BYOH Provisioning with terraform-windows-provisioner ==="

# Generate unique suffix using 3 random alphanumeric characters (0-9, a-z)
# Windows NetBIOS limit: base name ≤ 8 chars (VM name will be base + "-<index>")
# "byoh-" (5 chars) + 3 alphanumeric chars = 8 chars (within limit)
# 36^3 = 46,656 possibilities for collision avoidance
CHARS="0123456789abcdefghijklmnopqrstuvwxyz"
UNIQUE_SUFFIX=""
UNIQUE_SUFFIX+=${CHARS:$((RANDOM % 36)):1}
UNIQUE_SUFFIX+=${CHARS:$((RANDOM % 36)):1}
UNIQUE_SUFFIX+=${CHARS:$((RANDOM % 36)):1}
export BYOH_INSTANCE_NAME="${BYOH_INSTANCE_NAME:-byoh-${UNIQUE_SUFFIX}}"
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-2}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"
# Terraform state can contain credentials. Keep it only in protected shared storage.
export BYOH_TMP_DIR="${SHARED_DIR}/terraform_byoh/"
mkdir -p "${BYOH_TMP_DIR}"
trap handle_exit EXIT

echo "Using unique instance name: ${BYOH_INSTANCE_NAME}"

# Save instance name to SHARED_DIR for destroy step
echo "${BYOH_INSTANCE_NAME}" > "${SHARED_DIR}/byoh_instance_name.txt"
echo "Saved instance name to ${SHARED_DIR}/byoh_instance_name.txt"

# Windows credentials
# WINC_ADMIN_PASSWORD will be auto-generated by byoh.sh if not provided
# WINC_SSH_PUBLIC_KEY must be provided - extract from cluster profile
if [[ -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
    WINC_SSH_PUBLIC_KEY=$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")
    export WINC_SSH_PUBLIC_KEY
    echo "SSH public key loaded from cluster profile"
else
    echo "ERROR: ${CLUSTER_PROFILE_DIR}/ssh-publickey not found"
    exit 1
fi

# Export credentials from cluster profile (platform-agnostic)
# terraform-windows-provisioner will auto-detect platform and use appropriate credentials
if [[ -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_PROFILE="default"
    echo "AWS credentials configured"
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" ]]; then
    ARM_CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID
    echo "Azure credentials configured"
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/gce.json" ]]; then
    GOOGLE_CREDENTIALS=$(cat "${CLUSTER_PROFILE_DIR}/gce.json")
    export GOOGLE_CREDENTIALS
    echo "GCP credentials configured"
fi

# Load AWS Windows AMI and region from SHARED_DIR if available (for UPI workflows)
if [[ -f "${SHARED_DIR}/AWS_WINDOWS_AMI" ]]; then
    AWS_WINDOWS_AMI=$(cat "${SHARED_DIR}/AWS_WINDOWS_AMI")
    export AWS_WINDOWS_AMI
    echo "Loaded AWS_WINDOWS_AMI from SHARED_DIR"
else
    echo "AWS_WINDOWS_AMI file not found in SHARED_DIR"
fi

if [[ -f "${SHARED_DIR}/AWS_REGION" ]]; then
    AWS_REGION=$(cat "${SHARED_DIR}/AWS_REGION")
    export AWS_REGION
    export AWS_DEFAULT_REGION="${AWS_REGION}"
    echo "Loaded AWS region from SHARED_DIR"
else
    echo "ERROR: AWS_REGION file not found at ${SHARED_DIR}/AWS_REGION"
fi

# Debug platform detection logic to verify assumptions
echo "=== Platform Detection Debug ==="
DETECTED_PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "FAILED")
echo "Infrastructure platformStatus.type: ${DETECTED_PLATFORM}"

MACHINESETS_COUNT=$(oc get machinesets -n openshift-machine-api --no-headers 2>/dev/null | wc -l || echo "0")
echo "MachineSets count in openshift-machine-api: ${MACHINESETS_COUNT}"

MACHINES_COUNT=$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker --no-headers 2>/dev/null | wc -l || echo "0")
echo "Worker Machines count in openshift-machine-api: ${MACHINES_COUNT}"

if [[ "${MACHINESETS_COUNT}" -eq 0 ]]; then
    echo "UPI Detection: No MachineSets found → Will use platform=none"
else
    echo "IPI Detection: ${MACHINESETS_COUNT} MachineSets found → Will use platform=${DETECTED_PLATFORM}"
fi
echo "=== End Platform Detection Debug ==="

# Start early capture BEFORE terraform apply / BYOH registration.
# This captures Windows Node metadata and AWS CCM state during the window when
# nodes are created and then quickly deleted. Read-only; no cluster changes.
start_node_watcher
start_ccm_watcher

# Verify terraform and byoh.sh are available (pre-installed in terraform-windows-provisioner image)
if ! command -v terraform &> /dev/null; then
    echo "ERROR: terraform command not found in terraform-windows-provisioner image"
    exit 1
fi
if [[ ! -x "${BYOH_PROVISIONER_DIR}/byoh.sh" ]]; then
    echo "ERROR: byoh.sh not found in terraform-windows-provisioner image"
    exit 1
fi
terraform version -no-color
echo "Terraform and byoh.sh found in image"

# Change to provisioner directory (scripts and configs are pre-installed in image)
cd "${BYOH_PROVISIONER_DIR}"

echo "Provisioning ${BYOH_NUM_WORKERS} Windows ${BYOH_WINDOWS_VERSION} nodes..."
set +o errexit
./byoh.sh apply "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"
apply_status=$?
set -o errexit

# Persist cleanup state before readiness polling. A failed apply can still have created
# resources and usable partial state, so archive whatever the provisioner produced.
archive_status=0
archive_terraform_state || archive_status=$?
if (( apply_status != 0 )); then
    echo "ERROR: BYOH provisioning command failed with exit status ${apply_status}"
    exit "${apply_status}"
fi
if (( archive_status != 0 )); then
    echo "ERROR: BYOH provisioning succeeded but cleanup state could not be saved"
    exit "${archive_status}"
fi

# Wait for BYOH nodes specifically to be Ready (identified by WMCO label)
# Default timeout: 45 minutes (vSphere provisioning takes longer than cloud platforms)
READY_TIMEOUT="${BYOH_READY_TIMEOUT:-45m}"
echo "Waiting for ${BYOH_NUM_WORKERS} BYOH Windows nodes to become Ready (timeout: ${READY_TIMEOUT})..."
# Export BYOH_NUM_WORKERS so it's available in the subshell
export BYOH_NUM_WORKERS
timeout "${READY_TIMEOUT}" bash -c '
    loops=0
    max_loops=30
    sleep_seconds=60
    while (( loops < max_loops )); do
        # Count nodes where STATUS field (column 2) starts with "Ready" (not "NotReady")
        READY=$(oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true --no-headers 2>/dev/null | awk '\''$2 == "Ready" || $2 ~ /^Ready,/ {print}'\'' | wc -l)
        TOTAL=$(oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true --no-headers 2>/dev/null | wc -l)
        echo "[$loops/$max_loops] BYOH nodes ready: ${READY}/${TOTAL} (waiting for ${BYOH_NUM_WORKERS})"
        if [[ "${READY}" -ge "${BYOH_NUM_WORKERS}" ]]; then
            echo "All ${READY} BYOH Windows nodes are Ready"
            break
        fi
        ((loops++))
        sleep "$sleep_seconds"
    done
    if (( loops >= max_loops )); then
        echo "Timeout: Only ${READY}/${BYOH_NUM_WORKERS} BYOH nodes became Ready after ${max_loops} attempts"
        oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true \
            -o "custom-columns=READY:.status.conditions[?(@.type==\"Ready\")].status,OS:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion" || true
        exit 1
    fi
'

# Stop background watchers now that provisioning is complete
stop_watchers

echo "Windows BYOH nodes provisioned successfully"
echo "All Windows nodes in cluster (sanitized):"
oc get nodes -l kubernetes.io/os=windows \
    -o 'custom-columns=READY:.status.conditions[?(@.type=="Ready")].status,OS:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion'
echo ""
echo "BYOH nodes specifically (labeled windowsmachineconfig.openshift.io/byoh=true):"
oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true \
    -o 'custom-columns=READY:.status.conditions[?(@.type=="Ready")].status,OS:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion'

# Export instance information for WMCO BYOH e2e tests
echo "Exporting Windows instance information to SHARED_DIR for WMCO tests..."

# Detect which platform terraform-windows-provisioner actually used
# Don't query cluster - check which directory was created
PLATFORM=""
for p in aws azure gcp vsphere nutanix none; do
    if [[ -d "${BYOH_TMP_DIR}${p}" ]]; then
        PLATFORM="${p}"
        break
    fi
done

if [[ -z "${PLATFORM}" ]]; then
    echo "ERROR: No terraform platform directory found in ${BYOH_TMP_DIR}"
    exit 1
fi

TERRAFORM_DIR="${BYOH_TMP_DIR}${PLATFORM}"
echo "Detected terraform platform directory: ${PLATFORM}"

cd "${BYOH_PROVISIONER_DIR}"
INSTANCE_IPS=$(terraform -chdir="${TERRAFORM_DIR}" output -json instance_ip 2>/dev/null | jq -r '.[]' || echo "")

if [[ -z "${INSTANCE_IPS}" ]]; then
    echo "WARNING: No instance IPs found in Terraform output"
    # Fallback: get from node IPs (values stay in SHARED_DIR, not echoed to logs)
    INSTANCE_IPS=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
fi
# Instance IPs go to protected SHARED_DIR only — do not echo raw values to logs

# Determine username based on platform
case "${PLATFORM}" in
    azure)
        USERNAME="capi"
        ;;
    *)
        USERNAME="Administrator"
        ;;
esac

# Write instance files in WMCO BYOH format
# Format: ${SHARED_DIR}/<ip>_windows_instance.txt containing "username: <username>"
# Read into array to handle empty values and special characters properly
IFS=' ' read -r -a IP_ARRAY <<< "${INSTANCE_IPS}"
for ip in "${IP_ARRAY[@]}"; do
    [[ -z "$ip" ]] && continue  # Skip empty values
    instance_file="${SHARED_DIR}/${ip}_windows_instance.txt"
    cat > "${instance_file}" <<EOF
username: ${USERNAME}
EOF
    echo "Created instance file in SHARED_DIR"
done

echo "Instance information exported to protected SHARED_DIR for WMCO tests"

echo "=== Windows BYOH Provisioning Complete ==="
