#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

oc adm wait-for-stable-cluster --timeout=3h

observed_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}')
if [[ "${observed_profile}" != "Modern" ]]; then
  echo "Expected the installer default APIServer tlsSecurityProfile.type 'Modern', found '${observed_profile}'"
  exit 1
fi

echo "APIServer reports the installer default tlsSecurityProfile.type 'Modern'."
