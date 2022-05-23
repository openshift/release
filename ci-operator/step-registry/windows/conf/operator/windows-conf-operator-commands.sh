#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if ! oc get ns "${OO_INSTALL_NAMESPACE}"; then
  oc create ns "${OO_INSTALL_NAMESPACE}"
fi

oc create secret generic cloud-private-key \
  -n "${OO_INSTALL_NAMESPACE}" \
  --from-file=private-key.pem="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
