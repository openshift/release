#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

oc adm wait-for-stable-cluster --timeout=3h

observed_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}')
observed_adherence=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsAdherence}')

if [[ "${observed_profile}" != "${TLS_PROFILE_TYPE}" ]]; then
  echo "Expected APIServer tlsSecurityProfile.type '${TLS_PROFILE_TYPE}', found '${observed_profile}'"
  exit 1
fi

if [[ "${observed_adherence}" != "${TLS_ADHERENCE}" ]]; then
  echo "Expected APIServer tlsAdherence '${TLS_ADHERENCE}', found '${observed_adherence}'"
  exit 1
fi

echo "APIServer reports tlsSecurityProfile.type '${observed_profile}' and tlsAdherence '${observed_adherence}'."
