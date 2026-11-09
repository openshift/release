#!/bin/bash

# KubeVirt Lightweight VM Deployment and Verification Script
# This script deploys a lightweight VM with public images and performs comprehensive health checks
# for upgrade testing scenarios with pre-upgrade, post-upgrade, and cleanup modes

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Validate required files and variables
#=====================
if [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    echo "[ERROR] Managed cluster kubeconfig not found: ${SHARED_DIR}/managed-cluster-kubeconfig" >&2
    exit 1
fi

export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

#=====================
# Download jq if not available
#=====================
if ! command -v jq &> /dev/null; then
    echo "[INFO] Downloading jq..."
    curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-linux64 > /tmp/jq
    chmod +x /tmp/jq
fi

#=====================
# Configuration variables
#=====================
result_file="${ARTIFACT_DIR}/junit_pre_upgrade_results.xml"
suite_name="pre-upgrade-test"
vm_name="${CNV_VM_NAME:-vm-ephemeral}"
namespace="${CNV_VM_NAMESPACE:-default}"
csv_namespace="${CNV_CSV_NAMESPACE:-openshift-cnv}"
timeout="${CNV_VM_TIMEOUT:-300}"
work_dir="/tmp/kubevirt-test-$$"
kubectl_cmd="${CNV_KUBECTL_CMD:-oc}"
virtctl_cmd="${CNV_VIRTCTL_CMD:-virtctl}"
mode="${CNV_TEST_MODE:-pre-upgrade}"
vm_image="${CNV_VM_IMAGE:-quay.io/kubevirt/cirros-container-disk-demo:devel}"

# Colors for output (constants)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#=====================
# Logging functions
#=====================
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

#=====================
# JUnit XML functions
#=====================
# Initialize empty JUnit file
init_junit() {
    cat > "${result_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${suite_name}" tests="0" failures="0" errors="0" skipped="0">
</testsuite>
EOF
}

# Append a test case (pass/fail/skip)
add_testcase_xml() {
    local classname="$1"
    local name="$2"
    local status="$3"
    local message="${4:-}"
    local xml
    local temp_file

    case "${status}" in
        pass)
            xml=" <testcase classname=\"${classname}\" name=\"${name}\"/>"
            ;;
        fail)
            # Escape XML special characters in message
            message="${message//&/&amp;}"
            message="${message//</&lt;}"
            message="${message//>/&gt;}"
            message="${message//\"/&quot;}"
            message="${message//\'/&apos;}"
            xml=" <testcase classname=\"${classname}\" name=\"${name}\"><failure message=\"${message}\"/></testcase>"
            ;;
        skip)
            # Escape XML special characters in message
            message="${message//&/&amp;}"
            message="${message//</&lt;}"
            message="${message//>/&gt;}"
            message="${message//\"/&quot;}"
            message="${message//\'/&apos;}"
            xml=" <testcase classname=\"${classname}\" name=\"${name}\"><skipped message=\"${message}\"/></testcase>"
            ;;
        *)
            echo "Invalid status: ${status} (use pass|fail|skip)" >&2
            exit 1
            ;;
    esac

    # Use a temporary file approach to safely insert XML before </testsuite>
    temp_file="$(mktemp)"
    {
        while IFS= read -r line; do
            if [[ "${line}" == *"</testsuite>"* ]]; then
                printf '%s\n' "${xml}"
            fi
            printf '%s\n' "${line}"
        done < "${result_file}"
    } > "${temp_file}"
    mv "${temp_file}" "${result_file}"
}

# Update summary values
update_counts() {
    local tests
    local failures
    local skipped
    local temp_file

    # Count test cases, failures, and skipped tests
    tests="$(grep -c "<testcase" "${result_file}" 2>/dev/null || echo "0")"
    failures="$(grep -c "<failure" "${result_file}" 2>/dev/null || echo "0")"
    skipped="$(grep -c "<skipped" "${result_file}" 2>/dev/null || echo "0")"
    
    # Remove any newlines and ensure we have clean numeric values
    tests="$(echo "${tests}" | tr -d '\n\r' | grep -o '[0-9]*' || echo "0")"
    failures="$(echo "${failures}" | tr -d '\n\r' | grep -o '[0-9]*' || echo "0")"
    skipped="$(echo "${skipped}" | tr -d '\n\r' | grep -o '[0-9]*' || echo "0")"

    # Ensure variables are numeric (default to 0 if not)
    tests="${tests:-0}"
    failures="${failures:-0}"
    skipped="${skipped:-0}"

    # Use awk for more robust replacement (avoids sed escaping issues)
    temp_file="$(mktemp)"
    awk -v tests="${tests}" -v failures="${failures}" -v skipped="${skipped}" '
        {
            gsub(/tests="[0-9]+"/, "tests=\"" tests "\"")
            gsub(/failures="[0-9]+"/, "failures=\"" failures "\"")
            gsub(/skipped="[0-9]+"/, "skipped=\"" skipped "\"")
            print
        }
    ' "${result_file}" > "${temp_file}"
    mv "${temp_file}" "${result_file}"
}

#=====================
# VM manifest creation
#=====================
# Create custom VM manifest with public images
create_custom_manifest() {
    local manifest_path="$1"
    local vm_name_arg="$2" # Renamed to avoid conflict with global vm_name

    log_info "Creating custom VM manifest at ${manifest_path}"
    log_info "Using VM image: ${vm_image}"

    cat > "${manifest_path}" <<EOF
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  labels:
    special: ${vm_name_arg}
  name: ${vm_name_arg}
spec:
  running: true
  template:
    metadata:
      labels:
        special: ${vm_name_arg}
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
          image: ${vm_image}
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
            #!/bin/sh
            echo 'VM is ready for testing!'
            echo 'Login: cirros / Password: gocubsgo'
            echo 'VM Image: ${vm_image}'
            echo 'Current time: \$(date)'
        name: cloudinitdisk
EOF

    log_success "Custom VM manifest created successfully"
}

#=====================
# Setup and environment functions
#=====================
# Setup working environment
setup_working_environment() {
    log_info "Setting up working environment..."

    # Create work directory
    mkdir -p "${work_dir}"

    # Always create a custom manifest with public images
    local custom_manifest="${work_dir}/custom-vm-manifest.yaml"
    log_info "Creating custom VM manifest with public images..."
    create_custom_manifest "${custom_manifest}" "${vm_name}"
    vm_manifest="${custom_manifest}"

    log_success "Working environment setup completed"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if kubectl command exists
    if ! command -v "${kubectl_cmd}" &> /dev/null; then
        log_error "kubectl command not found: ${kubectl_cmd}"
        exit 1
    fi

    # Test kubectl connectivity
    if ! "${kubectl_cmd}" cluster-info &> /dev/null; then
        log_error "kubectl cannot connect to cluster. Please check your kubeconfig."
        exit 1
    fi

    # Check if KubeVirt is installed
    # Use explicit check: get api-resources output and verify it contains kubevirt.io
    local api_resources_output
    api_resources_output="$("${kubectl_cmd}" api-resources 2>/dev/null || echo "")"
    if [[ -z "${api_resources_output}" ]] || ! echo "${api_resources_output}" | grep -q kubevirt.io; then
        log_error "KubeVirt API resources not found. Please ensure KubeVirt is installed in the cluster."
        exit 1
    fi

    log_success "Prerequisites check passed"
}

#=====================
# VM deployment functions
#=====================
deploy_vm() {
    log_info "Deploying VM from manifest: ${vm_manifest}"

    # Check if VM manifest exists
    if [[ ! -f "${vm_manifest}" ]]; then
        log_error "VM manifest not found: ${vm_manifest}"
        return 1
    fi

    # Check if VM already exists
    if "${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" &> /dev/null; then
        local current_status
        current_status="$("${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "")"

        if [[ "${mode}" == "pre-upgrade" ]]; then
            log_warning "VM ${vm_name} already exists with status: ${current_status}. Cleaning up for fresh deployment..."
            cleanup_vm
            sleep 5
        elif [[ "${mode}" == "post-upgrade" ]] || [[ "${mode}" == "verify" ]]; then
            log_info "VM ${vm_name} already exists with status: ${current_status}. Skipping deployment."
            return 0
        else
            log_warning "VM ${vm_name} already exists with status: ${current_status}. Cleaning up..."
            cleanup_vm
            sleep 5
        fi
    fi

    # Deploy the VM (skip if in post-upgrade/verify mode and VM exists)
    "${kubectl_cmd}" create -f "${vm_manifest}" -n "${namespace}"
    log_success "VM ${vm_name} deployment initiated"
}

wait_for_vm_running() {
    log_info "Waiting for VM ${vm_name} to reach Running state (timeout: ${timeout}s)..."

    local elapsed=0
    local interval=5

    while (( elapsed < timeout )); do
        local phase
        phase="$("${kubectl_cmd}" get vmi "${vm_name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"

        case "${phase}" in
            "Running")
                log_success "VM ${vm_name} is now Running"
                return 0
                ;;
            "Failed")
                log_error "VM ${vm_name} failed to start"
                show_vm_details
                return 1
                ;;
            "Succeeded")
                log_warning "VM ${vm_name} completed execution"
                return 1
                ;;
            "")
                log_info "VM ${vm_name} not found yet..."
                ;;
            *)
                log_info "VM ${vm_name} current phase: ${phase}"
                ;;
        esac

        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_error "Timeout waiting for VM ${vm_name} to reach Running state"
    return 1
}

wait_for_pod_ready() {
    log_info "Waiting for launcher pod to be ready..."

    local elapsed=0
    local interval=5
    local pod_name=""

    # Wait for launcher pod to be created
    while (( elapsed < timeout )); do
        # Find the launcher pod by checking ownerReferences and Running status
        pod_name="$("${kubectl_cmd}" get pods -n "${namespace}" -l kubevirt.io=virt-launcher --field-selector=status.phase=Running -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${vm_name}'")].metadata.name}' 2>/dev/null || echo "")"

        if [[ -n "${pod_name}" ]]; then
            break
        fi

        log_info "Waiting for launcher pod to be created..."
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    if [[ -z "${pod_name}" ]]; then
        log_error "Launcher pod not found for VM ${vm_name} after ${timeout}s"
        log_info "Available pods in namespace ${namespace}:"
        "${kubectl_cmd}" get pods -n "${namespace}"
        log_info "Pods with virt-launcher label:"
        "${kubectl_cmd}" get pods -n "${namespace}" -l kubevirt.io=virt-launcher
        log_info "VM status:"
        "${kubectl_cmd}" get vmi "${vm_name}" -n "${namespace}" -o yaml | head -50
        return 1
    fi

    log_info "Found launcher pod: ${pod_name}"

    # Wait for pod to be ready
    if "${kubectl_cmd}" wait --for=condition=Ready "pod/${pod_name}" -n "${namespace}" --timeout="${timeout}s"; then
        log_success "Launcher pod ${pod_name} is ready"
        return 0
    else
        log_error "Launcher pod ${pod_name} failed to become ready"
        "${kubectl_cmd}" describe "pod/${pod_name}" -n "${namespace}"
        return 1
    fi
}

#=====================
# Health check functions
#=====================
# Check HyperConverged Operator status
check_hco_status() {
    log_info "Checking HyperConverged Operator (HCO) status..."

    # Check if jq is available
    local jq_cmd
    jq_cmd="$(command -v jq || echo "/tmp/jq")"
    if [[ ! -x "${jq_cmd}" ]]; then
        log_error "jq command not found or not executable - required for HCO status parsing"
        return 1
    fi

    # Check if HCO exists
    if ! "${kubectl_cmd}" get hco -A &> /dev/null; then
        log_warning "HyperConverged Operator not found (this may be normal in upstream KubeVirt)"
        return 0
    fi

    # Get HCO conditions
    local hco_conditions
    hco_conditions="$("${kubectl_cmd}" get hco -A -o jsonpath='{.items[0].status.conditions}' 2>/dev/null || echo "")"

    if [[ -z "${hco_conditions}" ]]; then
        log_warning "Could not retrieve HCO conditions"
        return 1
    fi

    # Check for Available condition using jq
    local available
    available="$(echo "${hco_conditions}" | "${jq_cmd}" -r '.[] | select(.type=="Available") | .status' 2>/dev/null || echo "")"
    local progressing
    progressing="$(echo "${hco_conditions}" | "${jq_cmd}" -r '.[] | select(.type=="Progressing") | .status' 2>/dev/null || echo "")"
    local degraded
    degraded="$(echo "${hco_conditions}" | "${jq_cmd}" -r '.[] | select(.type=="Degraded") | .status' 2>/dev/null || echo "")"

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

    return 0
}

# Check CSV status
check_csv_status() {
    log_info "Checking ClusterServiceVersion (CSV) status in namespace: ${csv_namespace}..."

    # Check if the namespace exists
    if ! "${kubectl_cmd}" get namespace "${csv_namespace}" &> /dev/null; then
        log_error "Namespace ${csv_namespace} does not exist"
        return 1
    fi

    # Get CSVs in the specified namespace
    local csvs
    csvs="$("${kubectl_cmd}" get csv -n "${csv_namespace}" --no-headers 2>/dev/null || echo "")"

    if [[ -z "${csvs}" ]]; then
        log_error "No CSVs found in namespace ${csv_namespace}"
        return 1
    fi

    log_info "Found CSVs in namespace: ${csv_namespace}"

    # Check each CSV phase - all must be "Succeeded"
    local all_succeeded=true
    while IFS= read -r csv_line; do
        if [[ -n "${csv_line}" ]]; then
            local csv_name
            csv_name="$(echo "${csv_line}" | awk '{print $1}')"
            local csv_phase
            csv_phase="$(echo "${csv_line}" | awk '{print $6}')"

            if [[ "${csv_phase}" == "Succeeded" ]]; then
                log_success "CSV ${csv_name}: ${csv_phase}"
            else
                log_error "CSV ${csv_name}: ${csv_phase} (expected: Succeeded)"
                all_succeeded=false
            fi
        fi
    done <<< "${csvs}"

    if [[ "${all_succeeded}" == "false" ]]; then
        log_error "One or more CSVs are not in Succeeded phase in namespace ${csv_namespace}"
        return 1
    fi

    log_success "All CSVs in namespace ${csv_namespace} are in Succeeded phase"
    return 0
}

# Check SSH connectivity to VM
check_ssh_connectivity() {
    log_info "Testing SSH connectivity to VM..."

    if ! command -v "${virtctl_cmd}" &> /dev/null; then
        log_error "virtctl not available: ${virtctl_cmd}"
        log_error "SSH connectivity test failed - virtctl is required"
        return 1
    fi

    # Test SSH connectivity using virtctl ssh
    log_info "Attempting SSH connection via virtctl..."

    # For CirrOS, the default credentials are 'Login: cirros / Password: gocubsgo'
    # We'll try a simple command that should work without password prompt
    local ssh_test_result=""

    # Clean up any existing known_hosts entry for this VM to avoid host key conflicts
    local vm_host
    vm_host="vmi.${vm_name}.${namespace}"
    if [[ -f ~/.ssh/known_hosts ]]; then
        ssh-keygen -R "${vm_host}" 2>/dev/null || true
    fi
    sleep 5
    # Try virtctl ssh with a simple command and timeout, bypassing host key checking
    ssh_test_result="$(timeout 10s sshpass -p "gocubsgo" "${virtctl_cmd}" ssh "cirros@vmi/${vm_name}" -n "${namespace}" --command="echo 'SSH_TEST_SUCCESS'" -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" 2>&1 || echo "failed")"

    if [[ "${ssh_test_result}" =~ "SSH_TEST_SUCCESS" ]]; then
        log_success "SSH connectivity to VM ${vm_name} is working"
        log_info "SSH access available with: ${virtctl_cmd} ssh cirros@vmi/${vm_name} -n ${namespace}"
        add_testcase_xml "VM deployment check" "SSH access available with: ${virtctl_cmd} ssh cirros@vmi/${vm_name} -n ${namespace}" pass
        return 0
    else
        # Try alternative methods to determine the specific failure
        log_warning "Direct SSH via virtctl failed, analyzing connection..."

        # Check if we can at least establish connection (even if auth fails)
        local connection_test
        connection_test="$(timeout 5s sshpass -p "gocubsgo" "${virtctl_cmd}" ssh "cirros@vmi/${vm_name}" -n "${namespace}" --command="exit" -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" 2>&1 || echo "")"
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
            log_error "SSH connectivity test failed with unexpected error: ${connection_test}"
            add_testcase_xml "SSH Connectivity check" "SSH connectivity test failed" fail "SSH connectivity test failed with unexpected error: ${connection_test}"
            return 1
        fi
    fi
}

#=====================
# VM information and cleanup functions
#=====================
# Show detailed VM information
show_vm_details() {
    log_info "VM Details:"
    echo "============================================"

    # VM status
    echo "VM Status:"
    "${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" -o wide 2>/dev/null || log_warning "Could not get VM status"
    echo ""

    # VMI status (if exists)
    echo "VMI Status:"
    "${kubectl_cmd}" get vmi "${vm_name}" -n "${namespace}" -o wide 2>/dev/null || log_warning "Could not get VMI status (VM may not be running)"
    echo ""

    # VM description
    echo "VM Description:"
    "${kubectl_cmd}" describe vm "${vm_name}" -n "${namespace}" 2>/dev/null || log_warning "Could not describe VM"
    echo ""

    # VMI description
    echo "VMI Description:"
    "${kubectl_cmd}" describe vmi "${vm_name}" -n "${namespace}" 2>/dev/null || log_warning "Could not describe VMI"
    echo ""

    # Launcher pod status
    echo "Launcher Pod Status:"
    local pod_name
    pod_name="$("${kubectl_cmd}" get pods -n "${namespace}" -l kubevirt.io=virt-launcher --field-selector=status.phase=Running -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${vm_name}'")].metadata.name}' 2>/dev/null || echo "")"

    if [[ -n "${pod_name}" ]]; then
        "${kubectl_cmd}" get pod "${pod_name}" -n "${namespace}" -o wide
        echo ""
        echo "Pod Events:"
        "${kubectl_cmd}" get events --field-selector "involvedObject.name=${pod_name}" -n "${namespace}" --sort-by='.lastTimestamp' | tail -10
    else
        log_warning "Launcher pod not found"
        echo "All pods in namespace:"
        "${kubectl_cmd}" get pods -n "${namespace}"
    fi
    echo "============================================"
}

# Cleanup function
cleanup_vm() {
    log_info "Cleaning up VM ${vm_name}..."

    if "${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" &> /dev/null; then
        "${kubectl_cmd}" delete vm "${vm_name}" -n "${namespace}" --timeout=60s

        # Wait for VM to be fully deleted
        local elapsed=0
        while "${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" &> /dev/null && (( elapsed < 60 )); do
            sleep 2
            elapsed=$((elapsed + 2))
        done

        if "${kubectl_cmd}" get vm "${vm_name}" -n "${namespace}" &> /dev/null; then
            log_warning "VM ${vm_name} is still present after cleanup attempt"
        else
            log_success "VM ${vm_name} cleaned up successfully"
        fi
    else
        log_info "VM ${vm_name} not found (already cleaned up)"
    fi
}

#=====================
# Main function
#=====================
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

        log_success "VM ${vm_name} is ready for upgrade testing!"
        log_info "VM will remain running for upgrade verification."
        log_info "Run with --mode post-upgrade after the upgrade to verify functionality."
    else
        log_error "VM deployment failed in pre-upgrade mode"
        show_vm_details
        exit 1
    fi
    update_counts
}

main_pre_upgrade
