#! /bin/bash

# Deploys the Shared Resource CSI Driver onto the cluster
#
# The following environment variables can be provided as image dependencies:
#
# - DRIVER_IMAGE: reference to the CSI driver image
# - NODE_REGISTRAR_IMAGE: reference to the CSI node registrar image

echo "Starting step csi-driver-shared-resource-deploy."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping deployment of csi-driver-shared-resource."
    exit 0
fi

echo "Deploying csi-driver-shared-resource via manual scripting"
make deploy
echo "Completed step csi-driver-shared-resource-deploy".
