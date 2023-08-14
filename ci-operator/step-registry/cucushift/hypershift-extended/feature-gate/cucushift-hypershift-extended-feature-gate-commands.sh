#!/bin/bash

export LC_CTYPE=C
set -o nounset
set -o errexit
set -o pipefail

if [ -z "$HYPERSHIFT_FEATURE_SET" ] ; then
  echo "HYPERSHIFT_FEATURE_SET is empty, skip feature set config step"
  exit 0
fi

MC_KUBECONFIG_FILE="${SHARED_DIR}/hs-mc.kubeconfig"
if [ -f "${MC_KUBECONFIG_FILE}" ]; then
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  _jsonpath="{.items[?(@.metadata.name==\"$(cat ${SHARED_DIR}/cluster-name)\")].metadata.namespace}"
  HYPERSHIFT_NAMESPACE=$(oc get hostedclusters -A -ojsonpath="$_jsonpath")
else
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

count=$(oc get hostedclusters --no-headers --ignore-not-found -n "$HYPERSHIFT_NAMESPACE" | wc -l)
echo "hostedcluster count: $count"
if [ "$count" -lt 1 ]  ; then
    echo "namespace clusters don't have hostedcluster"
    exit 1
fi

#limitation: we always & only select the first hostedcluster to add idp-htpasswd. "
cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# add feature set to the hosted cluster
oc patch hostedclusters $cluster_name -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"configuration":{"featureGate":{"featureSet":"'$HYPERSHIFT_FEATURE_SET'"}}}}'
oc get hostedclusters $cluster_name -n "$HYPERSHIFT_NAMESPACE" -ojsonpath='{.spec.configuration.featureGate}' | jq
