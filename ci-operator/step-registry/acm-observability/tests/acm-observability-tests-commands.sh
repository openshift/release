#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

# Login to the ACM hub cluster as kube:admin
KUBEADMIN_PASSWORD=$(cat ${SHARED_DIR}/${HUB_CLUSTER_NAME}/kubeadmin-password)
oc login --username=kubeadmin --password=${KUBEADMIN_PASSWORD}

# Run ACM Observability tests
KUBEADMIN_TOKEN=$(oc whoami -t)
export KUBEADMIN_TOKEN
poetry run pytest -m acm_observability --cluster-name=${HUB_CLUSTER_NAME}