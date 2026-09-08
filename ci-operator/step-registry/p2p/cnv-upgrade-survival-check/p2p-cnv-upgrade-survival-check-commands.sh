#!/bin/bash
#
# Verify that CNV test VMs survived the OCP upgrade.
# Checks all VMs created by p2p-create-migration-test-vm and confirms they are running.
# Requires p2p-create-migration-test-vm to have run first (creates test-vm-1 .. test-vm-N).
#
set -euxo pipefail; shopt -s inherit_errexit

[[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

typeset vmCount="${CNV_TEST_VM_COUNT:-1}"
typeset vmNamespace="${CNV_TEST_VM_NAMESPACE:-vm-migration-test}"
typeset vmFailures=0 vmSuccess=0
typeset idx='' vmName='' vmiName=''

: "Checking CNV VM survival after upgrade (${vmCount} VMs in namespace ${vmNamespace})"

# Loop through all created VMs
for ((idx = 1; idx <= vmCount; idx++)); do
    vmName="test-vm-${idx}"
    
    : "Checking VM: ${vmName}"
    
    # Check if VM exists
    if ! oc get vm "${vmName}" -n "${vmNamespace}" >/dev/null 2>&1; then
        : "ERROR: VM ${vmName} not found in namespace ${vmNamespace}"
        ((vmFailures++))
        continue
    fi
    
    # Check if VMI (running instance) exists and is in Running phase
    vmiName="$(oc get vmi "${vmName}" -n "${vmNamespace}" -o jsonpath='{.metadata.name}' --ignore-not-found 2>/dev/null || echo '')"
    if [[ -z "${vmiName}" ]]; then
        : "ERROR: VMI ${vmName} not running (no instance found)"
        ((vmFailures++))
        oc describe vm "${vmName}" -n "${vmNamespace}" | head -20 || true
        continue
    fi
    
    # Check VMI phase
    typeset vmiPhase=''
    vmiPhase="$(oc get vmi "${vmName}" -n "${vmNamespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
    if [[ "${vmiPhase}" != "Running" ]]; then
        : "ERROR: VM ${vmName} VMI phase is ${vmiPhase}, expected Running"
        ((vmFailures++))
        oc describe vmi "${vmName}" -n "${vmNamespace}" | head -20 || true
        continue
    fi
    
    : "SUCCESS: VM ${vmName} is running (phase: ${vmiPhase})"
    ((vmSuccess++))
done

: "=========================================="
: "CNV VM Survival Check Results"
: "=========================================="
: "Total VMs checked: ${vmCount}"
: "Survived upgrade: ${vmSuccess}"
: "Failed/not found: ${vmFailures}"
: "=========================================="

if [[ ${vmFailures} -gt 0 ]]; then
    : "ERROR: ${vmFailures} VM(s) did not survive the upgrade"
    exit 1
fi

: "SUCCESS: All ${vmSuccess} VM(s) survived the upgrade and are running"
true
