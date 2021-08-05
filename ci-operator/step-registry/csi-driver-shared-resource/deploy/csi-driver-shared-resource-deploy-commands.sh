#! /bin/bash

echo "Starting step csi-driver-shared-resource-deploy."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping deployment of csi-driver-shared-resource."
    exit 0
fi

deploy/deploy-in-CI.sh

echo "Completed step csi-driver-shared-resource-deploy".
