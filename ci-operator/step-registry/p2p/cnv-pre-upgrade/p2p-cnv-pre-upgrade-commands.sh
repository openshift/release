#!/bin/bash

# KubeVirt Lightweight VM Deployment and Verification Script
# This script deploys a lightweight VM with public images and performs comprehensive health checks
# for upgrade testing scenarios with pre-upgrade, post-upgrade, and cleanup modes


set -euxo pipefail; shopt -s inherit_errexit


export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-linux64 > /tmp/jq
chmod +x /tmp/jq

RESULT_FILE="${ARTIFACT_DIR}/junit_pre_upgrade_results.xml"
SUITE_NAME="pre-upgrade-test"

# Initialize empty JUnit file
init_junit() {
cat > "$RESULT_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="$SUITE_NAME" tests="0" failures="0" errors="0" skipped="0">
</testsuite>
EOF
}

# Append a test case (pass/fail/skip)
add_testcase_xml() {
    local classname="$1"
    local name="$2"
    local status="$3"
    local message="${4:-}"

    case "$status" in
        pass)
            xml=" <testcase classname=\"$classname\" name=\"$name\"/>"
            ;;
        fail)
            xml=" <testcase classname=\"$classname\" name=\"$name\"><failure message=\"$message\"/></testcase>"
            ;;
        skip)
            xml=" <testcase classname=\"$classname\" name=\"$name\"><skipped message=\"$message\"/></testcase>"
            ;;
        *)
            echo "Invalid status: $status (use pass|fail|skip)" >&2
            exit 1
            ;;
    esac

    # Insert before </testsuite>
    sed -i "/<\/testsuite>/i $xml" "$RESULT_FILE"
}

# Update summary values
update_counts() {
    local tests failures skipped
    tests=$(grep -c "<testcase" "$RESULT_FILE" || true)
    failures=$(grep -c "<failure" "$RESULT_FILE" || true)
    skipped=$(grep -c "<skipped" "$RESULT_FILE" || true)

    sed -i "s/tests=\"[0-9]*\"/tests=\"$tests\"/" "$RESULT_FILE"
    sed -i "s/failures=\"[0-9]*\"/failures=\"$failures\"/" "$RESULT_FILE"
    sed -i "s/skipped=\"[0-9]*\"/skipped=\"$skipped\"/" "$RESULT_FILE"
}


# Configuration
VM_NAME="vm-ephemeral"
NAMESPACE="default"
CSV_NAMESPACE="openshift-cnv"
TIMEOUT="300"
WORK_DIR="/tmp/kubevirt-test-$$"
KUBECTL_CMD="oc"
VIRTCTL_CMD="virtctl"
MODE="pre-upgrade"
VM_IMAGE="quay.io/kubevirt/cirros-container-disk-demo:devel"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create custom VM manifest with public images
create_custom_manifest() {
    local manifest_path="$1"
    local vm_name="$2"

    log_info "Creating custom VM manifest at ${manifest_path}"
    log_info "Using VM image: ${VM_IMAGE}"

    cat > $manifest_path << EOF
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  labels:
    special: ${vm_name}
  name: ${vm_name}
spec:
  running: true
  template:
    metadata:
      labels:
        special: ${vm_name}
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
        memory:
          guest: 128Mi
        resources: {}
      terminationGracePeriodSeconds: 0
      volumes:
      - containerDisk:
          image: ${VM_IMAGE}
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
            #!/bin/sh
            echo 'VM is ready for testing!'
            echo 'Login: cirros / Password: gocubsgo'
            echo 'VM Image: ${VM_IMAGE}'
            echo 'Current time: \$(date)'
        name: cloudinitdisk

EOF

    log_success "Custom VM manifest created successfully"
}

# Setup working environment
setup_working_environment() {
    log_info "Setting up working environment..."

    # Create work directory
    mkdir -p ${WORK_DIR}

    # Always create a custom manifest with public images
    local custom_manifest="${WORK_DIR}/custom-vm-manifest.yaml"
    log_info "Creating custom VM manifest with public images..."
    create_custom_manifest "${custom_manifest}" "${VM_NAME}"
    VM_MANIFEST="${custom_manifest}"

    log_success "Working environment setup completed"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if kubectl command exists
    if ! command -v ${KUBECTL_CMD} &> /dev/null; then
        log_error "kubectl command not found: ${KUBECTL_CMD}"
        exit 1
    fi

    # Test kubectl connectivity
    if ! ${KUBECTL_CMD} cluster-info &> /dev/null; then
        log_error "kubectl cannot connect to cluster. Please check your kubeconfig."
        exit 1
    fi

    # Check if KubeVirt is installed
    if ! ${KUBECTL_CMD} api-resources | grep kubevirt.io; then
        log_error "KubeVirt API resources not found. Please ensure KubeVirt is installed in the cluster."
        exit 1
    fi

    log_success "Prerequisites check passed"
}

deploy_vm() {
    log_info "Deploying VM from manifest: ${VM_MANIFEST}"

    # Check if VM manifest exists
    if [[ ! -f ${VM_MANIFEST} ]]; then
        log_error "VM manifest not found: ${VM_MANIFEST}"
        return 1
    fi

    # Check if VM already exists
    if ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} &> /dev/null; then
        local current_status
        current_status=$(${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "")

        if [[ "${MODE}" == "pre-upgrade" ]]; then
            log_warning "VM ${VM_NAME} already exists with status: ${current_status}. Cleaning up for fresh deployment..."
            cleanup_vm
            sleep 5
        elif [[ "${MODE}" == "post-upgrade" ]] || [[ "${MODE}" == "verify" ]]; then
            log_info "VM ${VM_NAME} already exists with status: ${current_status}. Skipping deployment."
            return 0
        else
            log_warning "VM ${VM_NAME} already exists with status: ${current_status}. Cleaning up..."
            cleanup_vm
            sleep 5
        fi
    fi

    # Deploy the VM (skip if in post-upgrade/verify mode and VM exists)
    ${KUBECTL_CMD} create -f ${VM_MANIFEST} -n ${NAMESPACE}
    log_success "VM ${VM_NAME} deployment initiated"
}

check_vm_exists() {
    if ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} &> /dev/null; then
        local status
        status=$(${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "")
        log_info "VM ${VM_NAME} exists with status: ${status}"
        return 0
    else
        log_warning "VM ${VM_NAME} does not exist"
        return 1
    fi
}

wait_for_vm_running() {
    log_info "Waiting for VM ${VM_NAME} to reach Running state (timeout: ${TIMEOUT}s)..."

    local elapsed=0
    local interval=5

    while [ ${elapsed} -lt ${TIMEOUT} ]; do
        local phase
        phase=$(${KUBECTL_CMD} get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        case ${phase} in
            "Running")
                log_success "VM ${VM_NAME} is now Running"
                return 0
                ;;
            "Failed")
                log_error "VM ${VM_NAME} failed to start"
                show_vm_details
                return 1
                ;;
            "Succeeded")
                log_warning "VM ${VM_NAME} completed execution"
                return 1
                ;;
            "")
                log_info "VM ${VM_NAME} not found yet..."
                ;;
            *)
                log_info "VM ${VM_NAME} current phase: ${phase}"
                ;;
        esac

        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    log_error "Timeout waiting for VM ${VM_NAME} to reach Running state"
    return 1
}


wait_for_pod_ready() {
    log_info "Waiting for launcher pod to be ready..."

    local elapsed=0
    local interval=5
    local pod_name=""

    # Wait for launcher pod to be created
    while [ ${elapsed} -lt ${TIMEOUT} ]; do
        # Find the launcher pod by checking ownerReferences and Running status
        pod_name=$(${KUBECTL_CMD} get pods -n ${NAMESPACE} -l kubevirt.io=virt-launcher --field-selector=status.phase=Running -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${VM_NAME}'")].metadata.name}' 2>/dev/null || echo "")

        if [[ -n "${pod_name}" ]]; then
            break
        fi

        log_info "Waiting for launcher pod to be created..."
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    if [[ -z "${pod_name}" ]]; then
        log_error "Launcher pod not found for VM ${VM_NAME} after ${TIMEOUT}s"
        log_info "Available pods in namespace ${NAMESPACE}:"
        ${KUBECTL_CMD} get pods -n ${NAMESPACE}
        log_info "Pods with virt-launcher label:"
        ${KUBECTL_CMD} get pods -n ${NAMESPACE} -l kubevirt.io=virt-launcher
        log_info "VM status:"
        ${KUBECTL_CMD} get vmi ${VM_NAME} -n ${NAMESPACE} -o yaml | head -50
        return 1
    fi

    log_info "Found launcher pod: ${pod_name}"

    # Wait for pod to be ready
    if ${KUBECTL_CMD} wait --for=condition=Ready pod/${pod_name} -n ${NAMESPACE} --timeout=${TIMEOUT}s; then
        log_success "Launcher pod ${pod_name} is ready"
        return 0
    else
        log_error "Launcher pod ${pod_name} failed to become ready"
        ${KUBECTL_CMD} describe pod/${pod_name} -n ${NAMESPACE}
        return 1
    fi
}

# Check HyperConverged Operator status
check_hco_status() {
    log_info "Checking HyperConverged Operator (HCO) status..."

    # Check if jq is available
    if ! command -v /tmp/jq &> /dev/null; then
        log_error "jq command not found - required for HCO status parsing"
        return 1
    fi

    # Check if HCO exists
    if ! ${KUBECTL_CMD} get hco -A &> /dev/null; then
        log_warning "HyperConverged Operator not found (this may be normal in upstream KubeVirt)"
        return 0
    fi

    # Get HCO conditions
    local hco_conditions
    hco_conditions=$(${KUBECTL_CMD} get hco -A -o jsonpath='{.items[0].status.conditions}' 2>/dev/null || echo "")

    if [[ -z "${hco_conditions}" ]]; then
        log_warning "Could not retrieve HCO conditions"
        return 1
    fi

    # Check for Available condition using jq
    local available
    available=$(echo "${hco_conditions}" | /tmp/jq -r '.[] | select(.type=="Available") | .status' 2>/dev/null || echo "")
    local progressing
    progressing=$(echo "${hco_conditions}" | /tmp/jq -r '.[] | select(.type=="Progressing") | .status' 2>/dev/null || echo "")
    local degraded
    degraded=$(echo "${hco_conditions}" | /tmp/jq -r '.[] | select(.type=="Degraded") | .status' 2>/dev/null || echo "")

    if [[ "${available}" == "True" ]]; then
        log_success "HCO is Available"
    else
        log_error "HCO is not Available (status: ${available})"
        return 1
    fi

    if [[ "${progressing}" == "False" ]]; then
        log_success "HCO is not Progressing (stable)"
    else
        log_warning "HCO is Progressing (upgrade/change in progress)"
    fi

    if [[ "${degraded}" == "False" ]]; then
        log_success "HCO is not Degraded"
    else
        log_error "HCO is Degraded (status: ${degraded})"
        return 1
    fi

    # Show HCO version if available
    local hco_version
    hco_version=$(${KUBECTL_CMD} get hco -A -o jsonpath='{.items[0].status.versions}' 2>/dev/null || echo "")
    if [[ -n "${hco_version}" ]]; then
        log_info "HCO version info available"
    fi

    return 0
}

#===========check csv status================
check_csv_status() {
    log_info "Checking ClusterServiceVersion (CSV) status in namespace: ${CSV_NAMESPACE}..."

    # Check if the namespace exists
    if ! ${KUBECTL_CMD} get namespace "${CSV_NAMESPACE}" &> /dev/null; then
        log_error "Namespace ${CSV_NAMESPACE} does not exist"
        return 1
    fi

    # Get CSVs in the specified namespace
    local csvs
    csvs=$(${KUBECTL_CMD} get csv -n "${CSV_NAMESPACE}" --no-headers 2>/dev/null || echo "")

    if [[ -z "${csvs}" ]]; then
        log_error "No CSVs found in namespace ${CSV_NAMESPACE}"
        return 1
    fi

    log_info "Found CSVs in namespace: ${CSV_NAMESPACE}"

    # Check each CSV phase - all must be "Succeeded"
    local all_succeeded=true
    while IFS= read -r csv_line; do
        if [[ -n "${csv_line}" ]]; then
            local csv_name
            csv_name=$(echo "${csv_line}" | awk '{print $1}')
            local csv_phase
            csv_phase=$(echo "${csv_line}" | awk '{print $6}')

            if [[ "${csv_phase}" == "Succeeded" ]]; then
                log_success "CSV ${csv_name}: ${csv_phase}"
            else
                log_error "CSV ${csv_name}: ${csv_phase} (expected: Succeeded)"
                all_succeeded=false
            fi
        fi
    done <<< "${csvs}"

    if [[ "${all_succeeded}" == "false" ]]; then
        log_error "One or more CSVs are not in Succeeded phase in namespace ${CSV_NAMESPACE}"
        return 1
    fi

    log_success "All CSVs in namespace ${CSV_NAMESPACE} are in Succeeded phase"
    return 0
}

#===========================================

# Check SSH connectivity to VM
check_ssh_connectivity() {
    log_info "Testing SSH connectivity to VM..."

    if ! command -v ${VIRTCTL_CMD} &> /dev/null; then
        log_error "virtctl not available: ${VIRTCTL_CMD}"
        log_error "SSH connectivity test failed - virtctl is required"
        return 1
    fi

    # Get VM IP address first
    local vm_ip
    vm_ip=$(${KUBECTL_CMD} get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")

    if [[ -z "${vm_ip}" ]]; then
        log_error "Could not get VM IP address for SSH test"
        log_error "VM may not have network connectivity"
        
        return 1
    fi

    log_info "VM IP address: ${vm_ip}"

    # Test SSH connectivity using virtctl ssh
    log_info "Attempting SSH connection via virtctl..."

    # For CirrOS, the default credentials are 'Login: cirros / Password: gocubsgo'
    # We'll try a simple command that should work without password prompt
    local ssh_test_result=""

    # Clean up any existing known_hosts entry for this VM to avoid host key conflicts
    local vm_host
    vm_host="vmi.${VM_NAME}.${NAMESPACE}"
    if [[ -f ~/.ssh/known_hosts ]]; then
        ssh-keygen -R "${vm_host}" 2>/dev/null || true
    fi
    sleep 5
    # Try virtctl ssh with a simple command and timeout, bypassing host key checking
    ssh_test_result=$(timeout 10s sshpass -p "gocubsgo" ${VIRTCTL_CMD} ssh cirros@vmi/${VM_NAME} -n ${NAMESPACE} --command="echo 'SSH_TEST_SUCCESS'" -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" 2>&1 || echo "failed")

    if [[ "${ssh_test_result}" =~ "SSH_TEST_SUCCESS" ]]; then
        log_success "SSH connectivity to VM ${VM_NAME} is working"
        log_info "SSH access available with: ${VIRTCTL_CMD} ssh cirros@vmi/${VM_NAME} -n ${NAMESPACE}"
        add_testcase_xml "VM deployement check" "SSH access available with: ${VIRTCTL_CMD} ssh cirros@vmi/${VM_NAME} -n ${NAMESPACE}" pass
        return 0
    else
        # Try alternative methods to determine the specific failure
        log_warning "Direct SSH via virtctl failed, analyzing connection..."
        #sshpass -p 'gocubsgo' ${VIRTCTL_CMD} ssh cirros@vmi/${VM_NAME} -n ${NAMESPACE} -t '-o StrictHostKeyChecking=no'"

        # Check if we can at least establish connection (even if auth fails)
        local connection_test
        connection_test=$(timeout 5s sshpass -p "gocubsgo" ${VIRTCTL_CMD} ssh cirros@vmi/${VM_NAME} -n ${NAMESPACE} --command="exit" -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" 2>&1 || echo "")
        echo "connection-test: ${connection_test}"
        if [[ "${connection_test}" =~ "Permission denied" ]] || [[ "${connection_test}" =~ "password" ]] || [[ "${connection_test}" =~ "Host key verification failed" ]]; then
            log_error "SSH connectivity test failed - authentication required"
            add_testcase_xml "SSH Connectivity check" "SSH connectivity test failed" fail "SSH connectivity test failed - authentication required"
            
            return 1
        elif [[ "${connection_test}" =~ "Connection refused" ]]; then
            log_error "SSH connectivity test failed - service not available"
            add_testcase_xml "SSH Connectivity check" "SSH connectivity test failed" fail "SSH connectivity test failed - service not available"
            return 1
        elif [[ "${connection_test}" =~ "No route to host" ]] || [[ "${connection_test}" =~ "timeout" ]]; then
            log_error "SSH connection timeout - network connectivity issues"
            add_testcase_xml "SSH Connectivity check" "SSH connectivity test failed" fail "SSH connection timeout - network connectivity issues"
            return 1
        else
            log_error "SSH connectivity test failed with unexpected errorr: ${connection_test}"
            add_testcase_xml "SSH Connectivity check" "SSH connectivity test failed" fail "SSH connectivity test failed with unexpected errorr: ${connection_test}"
            return 1
        fi
    fi
}

# Show detailed VM information
show_vm_details() {
    log_info "VM Details:"
    echo "============================================"

    # VM status
    echo "VM Status:"
    ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} -o wide 2>/dev/null || log_warning "Could not get VM status"
    echo ""

    # VMI status (if exists)
    echo "VMI Status:"
    ${KUBECTL_CMD} get vmi ${VM_NAME} -n ${NAMESPACE} -o wide 2>/dev/null || log_warning "Could not get VMI status (VM may not be running)"
    echo ""

    # VM description
    echo "VM Description:"
    ${KUBECTL_CMD} describe vm ${VM_NAME} -n ${NAMESPACE} 2>/dev/null || log_warning "Could not describe VM"
    echo ""

    # VMI description
    echo "VMI Description:"
    ${KUBECTL_CMD} describe vmi ${VM_NAME} -n ${NAMESPACE} 2>/dev/null || log_warning "Could not describe VMI"
    echo ""

    # Launcher pod status
    echo "Launcher Pod Status:"
    local pod_name
    pod_name=$(${KUBECTL_CMD} get pods -n ${NAMESPACE} -l kubevirt.io=virt-launcher --field-selector=status.phase=Running -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${VM_NAME}'")].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${pod_name}" ]]; then
        ${KUBECTL_CMD} get pod ${pod_name} -n ${NAMESPACE} -o wide
        echo ""
        echo "Pod Events:"
        ${KUBECTL_CMD} get events --field-selector involvedObject.name=${pod_name} -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -10
    else
        log_warning "Launcher pod not found"
        echo "All pods in namespace:"
        ${KUBECTL_CMD} get pods -n ${NAMESPACE}
    fi
    echo "============================================"
}

# Cleanup function
cleanup_vm() {
    log_info "Cleaning up VM ${VM_NAME}..."

    if ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} &> /dev/null; then
        ${KUBECTL_CMD} delete vm ${VM_NAME} -n ${NAMESPACE} --timeout=60s

        # Wait for VM to be fully deleted
        local elapsed=0
        while ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} &> /dev/null && [ ${elapsed} -lt 60 ]; do
            sleep 2
            elapsed=$((elapsed + 2))
        done

        if ${KUBECTL_CMD} get vm ${VM_NAME} -n ${NAMESPACE} &> /dev/null; then
            log_warning "VM ${VM_NAME} is still present after cleanup attempt"
        else
            log_success "VM ${VM_NAME} cleaned up successfully"
        fi
    else
        log_info "VM ${VM_NAME} not found (already cleaned up)"
    fi
}

# Main function for pre-upgrade mode
main_pre_upgrade() {
    log_info "=== PRE-UPGRADE MODE ==="
    log_info "Creating VM to persist through upgrade process"
    init_junit
    # Run checks
    check_prerequisites

    # Setup working environment
    setup_working_environment

    # Deploy VM
    deploy_vm

    if wait_for_vm_running; then
        # Try to wait for pod ready, but don't fail if we can't find it
        if ! wait_for_pod_ready; then
            log_warning "Could not verify launcher pod, but VM is running. Continuing with other checks..."
        fi
        
        # Critical checks - if any fail, the script should exit
        if ! check_ssh_connectivity; then
            log_error "SSH connectivity check failed - VM deployment unsuccessful"
            show_vm_details
            exit 1
        fi

        if ! check_hco_status; then
            log_error "HCO status check failed - KubeVirt environment not healthy before upgrade"
            exit 1
        fi

        if ! check_csv_status; then
            log_error "CSV status failed - KubeVirt environment not ready"
            exit 1
        fi

        log_success "VM ${VM_NAME} is ready for upgrade testing!"
        log_info "VM will remain running for upgrade verification."
        log_info "Run with --mode post-upgrade after the upgrade to verify functionality."

        # Remove VM cleanup trap, keep only workdir cleanup
        # trap 'cleanup_workdir' EXIT
    else
        log_error "VM deployment failed in pre-upgrade mode"
        show_vm_details
        exit 1
    fi
    update_counts
}


main_pre_upgrade
