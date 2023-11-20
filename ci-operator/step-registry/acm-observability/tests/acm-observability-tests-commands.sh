#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 2h

KUBECONFIG=""
KUBEADMIN_PASSWORD=""

# Login to the hub cluster as kube:admin
export KUBECONFIG
oc login --username=kubeadmin --password=${KUBEADMIN_PASSWORD}

# Run ACM Observability tests
KUBEADMIN_TOKEN=$(oc whoami -t)
export KUBEADMIN_TOKEN
poetry run pytest -m acm_observability --cluster-name=${HUB_CLUSTER_NAME}