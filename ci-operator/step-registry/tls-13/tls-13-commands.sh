#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

oc adm wait-for-stable-cluster

tls_profile=$(oc get apiserver/cluster -ojson | jq -r .spec.tlsSecurityProfile.type)
if [[ "$tls_profile" != "Modern" ]]; then
  echo "Error: TLS Security Profile is '$tls_profile', expected 'Modern'"
  exit 1
fi
