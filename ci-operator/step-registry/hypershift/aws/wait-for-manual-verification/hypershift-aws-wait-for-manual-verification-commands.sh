#!/bin/bash

set -exuo pipefail

# Ensure that oc commands run against the management cluster
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

echo "================================================================================"
echo "MANUAL VERIFICATION WAIT POINT"
echo "================================================================================"
echo ""
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Namespace: clusters"
echo ""
echo "A test cluster has been created with NodePools. You can now inspect them."
echo ""
echo "QUICK COMMANDS:"
echo "-------------------------------------------------------------------------------"
echo ""
echo "  # List all NodePools"
echo "  oc get nodepool -n clusters"
echo ""
echo "  # Get first NodePool name"
echo "  NP=\$(oc get nodepool -n clusters -o jsonpath='{.items[0].metadata.name}')"
echo ""
echo "  # View NodePool YAML"
echo "  oc get nodepool -n clusters \$NP -o yaml"
echo ""
echo "  # Check imageType field (CNTRLPLANE-408)"
echo "  oc get nodepool -n clusters \$NP -o jsonpath='{.spec.platform.aws.imageType}'"
echo ""
echo "  # View all NodePool AWS fields"
echo "  oc explain nodepool.spec.platform.aws"
echo ""
echo "  # List HostedClusters"
echo "  oc get hostedcluster -n clusters"
echo ""
echo "  # View Machines (AWS instances)"
echo "  oc get machine -n clusters-${CLUSTER_NAME}"
echo ""
echo "CURRENT STATE:"
echo "-------------------------------------------------------------------------------"
echo ""
echo "HostedClusters:"
oc get hostedcluster -n clusters -o wide || true
echo ""
echo "NodePools:"
oc get nodepool -n clusters -o wide || true
echo ""
echo "Machines:"
oc get machine -n clusters-${CLUSTER_NAME} -o wide 2>/dev/null || echo "  (No machines found yet)"
echo ""
echo "================================================================================"
echo "Waiting ${WAIT_DURATION:-3600} seconds for manual verification..."
echo "To skip this wait, you can kill this step from the Prow UI."
echo "================================================================================"

sleep ${WAIT_DURATION:-3600}

echo ""
echo "Manual verification wait period completed."
echo "Proceeding with automated tests..."
