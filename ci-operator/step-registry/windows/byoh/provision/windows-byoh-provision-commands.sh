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
    })
    if printf '%s\n' "${diagnostic_output}" >"${output_file}"; then
        echo "Saved failure diagnostic: ${output_file}"
    else
        echo "WARNING: Could not write failure diagnostic: ${output_file}"
    fi
}

collect_failure_diagnostics() {
    echo "Collecting bounded WMCO failure diagnostics (best effort)..."
    capture_diagnostic wmco-workloads \
        oc get deployments,pods -n "${WMCO_NAMESPACE}" -o wide
    capture_diagnostic wmco-status \
        oc get csv,subscription -n "${WMCO_NAMESPACE}"
    capture_diagnostic wmco-logs \
        oc logs deployment/windows-machine-config-operator -n "${WMCO_NAMESPACE}" \
        --all-containers=true --prefix=true --since=30m --tail=500
    capture_diagnostic wmco-events \
        oc get events -n "${WMCO_NAMESPACE}" --sort-by=.lastTimestamp
    capture_diagnostic certificate-signing-requests \
        oc get csr
    capture_diagnostic windows-node-readiness \
        oc get nodes -l kubernetes.io/os=windows -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,READY_REASON:.status.conditions[?(@.type=="Ready")].reason,NETWORK_UNAVAILABLE:.status.conditions[?(@.type=="NetworkUnavailable")].status,OS_IMAGE:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion'
    echo "WMCO failure diagnostic collection finished"
}

handle_exit() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        set +o errexit
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
    echo "Loaded AWS_WINDOWS_AMI from SHARED_DIR: ${AWS_WINDOWS_AMI}"
else
    echo "AWS_WINDOWS_AMI file not found in SHARED_DIR"
fi

if [[ -f "${SHARED_DIR}/AWS_REGION" ]]; then
    AWS_REGION=$(cat "${SHARED_DIR}/AWS_REGION")
    export AWS_REGION
    export AWS_DEFAULT_REGION="${AWS_REGION}"
    echo "Loaded AWS region from SHARED_DIR: ${AWS_REGION}"
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
        oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true -o wide || true
        exit 1
    fi
'

echo "Windows BYOH nodes provisioned successfully"
echo "All Windows nodes in cluster:"
oc get nodes -l kubernetes.io/os=windows -o wide
echo ""
echo "BYOH nodes specifically (labeled windowsmachineconfig.openshift.io/byoh=true):"
oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true -o wide

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
    # Fallback: get from node IPs
    INSTANCE_IPS=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
fi

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
    echo "Created instance file: ${instance_file}"
done

echo "Instance information exported for WMCO BYOH tests"

echo "=== Windows BYOH Provisioning Complete ==="
