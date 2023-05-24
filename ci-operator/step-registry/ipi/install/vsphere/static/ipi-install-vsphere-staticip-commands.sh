#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

IPPOOL_FILE="${SHARED_DIR}/ipam-controller-ippool.yaml"

curl 'https://raw.githubusercontent.com/rvanderp3/machine-ipam-controller/main/hack/ci-resources.yaml' | envsubst | oc create -f -

echo "$(date -u --rfc-3339=seconds) - Deploying IPAM controller..."