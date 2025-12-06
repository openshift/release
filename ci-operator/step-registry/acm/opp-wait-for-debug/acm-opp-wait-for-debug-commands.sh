#!/bin/bash
set -o nounset
set -o pipefail

################################################################################
# Wait for Debug
################################################################################
# This step pauses test execution to allow manual inspection and debugging.
################################################################################

WAIT_DURATION="${WAIT_DURATION:-7200}"  # Default: 2 hours (in seconds)

echo "====== OPP Debug Wait Step ======"
echo ""
echo "Cluster is ready for debugging."
echo "Pausing for ${WAIT_DURATION} seconds ($(($WAIT_DURATION / 60)) minutes, $(($WAIT_DURATION / 3600)) hours)"
echo ""
echo "You can now exec into the Prow pod to run oc commands."
echo ""

# Display some useful information
echo "--- Current Cluster State ---"
echo ""
echo "QuayIntegration:"
oc get quayintegration -A 2>/dev/null || echo "  Not found"
echo ""

echo "ACM Policies:"
oc get policies -n policies 2>/dev/null || echo "  Not found"
echo ""

echo "Nodes:"
oc get nodes
echo ""

echo "====== Entering sleep mode for ${WAIT_DURATION} seconds ======"
echo "Start time: $(date)"
echo ""

# Sleep for the specified duration
sleep ${WAIT_DURATION}

echo ""
echo "====== Sleep completed ======"
echo "End time: $(date)"
echo ""

exit 0
