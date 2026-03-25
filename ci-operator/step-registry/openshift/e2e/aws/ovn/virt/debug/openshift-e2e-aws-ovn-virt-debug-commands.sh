#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Cluster is ready for debugging!"
echo "This step will sleep for 8 hours to allow manual investigation."
echo "Cluster credentials are available in the shared directory."
echo ""
echo "KUBECONFIG is set to: ${KUBECONFIG}"
echo ""
echo "To access the cluster, use the KUBECONFIG from the artifacts."
echo ""
echo "Sleep started at: $(date)"
echo "Will sleep until: $(date -d '+8 hours')"
echo ""

# Sleep for 8 hours (28800 seconds)
SLEEP_DURATION=28800
echo "Sleeping for ${SLEEP_DURATION} seconds (8 hours)..."
sleep ${SLEEP_DURATION}

echo ""
echo "Sleep completed at: $(date)"
echo "Debug session ended. Cluster will now be cleaned up."
