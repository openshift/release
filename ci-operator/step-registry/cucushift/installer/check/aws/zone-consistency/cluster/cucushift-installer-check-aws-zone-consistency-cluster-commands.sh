#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

echo "=========================================="
echo "OCPBUGS-69923: Verify Cluster Zone Consistency"
echo "=========================================="
echo ""

# Check required tools
if ! command -v oc >/dev/null 2>&1; then
    echo "Error: oc tool is required"
    exit 1
fi

# Check if kubeconfig exists
# kubeconfig is typically copied to SHARED_DIR after installation
KUBECONFIG_PATH="${KUBECONFIG:-${SHARED_DIR}/kubeconfig}"
if [ ! -f "$KUBECONFIG_PATH" ] && [ -f "/tmp/installer/auth/kubeconfig" ]; then
    KUBECONFIG_PATH="/tmp/installer/auth/kubeconfig"
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "Error: kubeconfig file does not exist"
    echo "       Please ensure cluster installation is complete"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Kubeconfig: $KUBECONFIG_PATH"
echo ""

# Check cluster connection
if ! oc cluster-info >/dev/null 2>&1; then
    echo "Error: Cannot connect to cluster"
    echo "       Please check if kubeconfig file is correct and cluster is ready"
    exit 1
fi

echo "✓ Successfully connected to cluster"
echo ""

# Get all master machines
MASTER_MACHINES=$(oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$MASTER_MACHINES" ]; then
    echo "❌ Error: No master machines found"
    echo "   Please ensure the cluster installation is complete"
    exit 1
fi

echo "Found $(echo $MASTER_MACHINES | wc -w | tr -d ' ') master machine(s)"
echo ""

# Verify zone consistency for each machine
echo "=========================================="
echo "Check Zone Consistency for Each Machine"
echo "=========================================="
echo ""

all_consistent=true
machine_count=0
ret=0

for machine in $MASTER_MACHINES; do
    machine_count=$((machine_count + 1))
    echo "--- Machine: $machine ---"
    
    # Get zone label
    zone_label=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.metadata.labels.machine\.openshift\.io/zone}' 2>/dev/null || echo "N/A")
    
    # Get zone from providerID
    provider_id=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.spec.providerID}' 2>/dev/null || echo "")
    provider_zone=$(echo "$provider_id" | grep -oP 'aws:///\K[^/]+' 2>/dev/null || echo "N/A")
    
    # Get availabilityZone from spec
    spec_zone=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.placement.availabilityZone}' 2>/dev/null || echo "N/A")
    
    echo "  Zone Label:        $zone_label"
    echo "  ProviderID Zone:  $provider_zone"
    echo "  Spec Zone:        $spec_zone"
    
    # Check consistency
    if [ "$zone_label" != "N/A" ] && [ "$provider_zone" != "N/A" ] && [ "$spec_zone" != "N/A" ]; then
        if [ "$zone_label" = "$provider_zone" ] && [ "$provider_zone" = "$spec_zone" ]; then
            echo "  ✅ Zone consistent"
        else
            echo "  ❌ Zone inconsistent!"
            all_consistent=false
            ret=$((ret + 1))
        fi
    else
        echo "  ⚠️  Warning: Some zone information is missing"
        if [ "$zone_label" != "$provider_zone" ] || [ "$provider_zone" != "$spec_zone" ]; then
            all_consistent=false
            ret=$((ret + 1))
        fi
    fi
    echo ""
done

# Summary
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo ""
echo "Checked $machine_count master machine(s)"
echo ""

if [ "$all_consistent" = true ]; then
    echo "✅ Cluster verification PASSED: All machines have consistent zones!"
    echo ""
    echo "Cluster verification: PASS ✓"
    echo ""
    echo "Fix verification successful:"
    echo "  - Zone label, ProviderID zone, and Spec zone are all consistent"
    echo "  - Machines are created in the correct availability zones"
    exit 0
else
    echo "❌ Cluster verification FAILED: Machines with inconsistent zones detected!"
    echo ""
    echo "Cluster verification: FAIL ✗"
    echo ""
    echo "Possible issues:"
    echo "  1. Fix not effective"
    echo "  2. Machines created in wrong availability zones"
    echo "  3. Zone label does not match actual zone"
    exit $ret
fi
