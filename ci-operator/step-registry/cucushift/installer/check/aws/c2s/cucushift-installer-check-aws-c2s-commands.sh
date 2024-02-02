#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Checking if CA exists in kube-cloud-config"
cloud_config=$(mktemp)
oc get configmap -n openshift-config-managed kube-cloud-config -oyaml > ${cloud_config}

# cabundle=$(mktemp)
# yq-go r ${cloud_config} 'data."ca-bundle.pem"' > ${cabundle}


if ! grep "BEGIN CERTIFICATE" ${cloud_config}; then
    echo "ERROR: No certification found, exit now."
    exit 1
else
    echo "PASS."
fi
