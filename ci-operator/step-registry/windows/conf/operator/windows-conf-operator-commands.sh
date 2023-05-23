#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if ! oc get ns "${SUB_INSTALL_NAMESPACE}"; then
  oc create ns "${SUB_INSTALL_NAMESPACE}"
fi

# Enable monitoring
oc label namespace "${SUB_INSTALL_NAMESPACE}" openshift.io/cluster-monitoring=true

oc create secret generic cloud-private-key \
  -n "${SUB_INSTALL_NAMESPACE}" \
  --from-file=private-key.pem="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
