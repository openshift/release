#!/bin/bash

set -euo pipefail

# Prefer the kubeconfig of the nested management cluster, as hypershift-install does.
if [[ -f "${SHARED_DIR}/management_cluster_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
fi

cert="${SHARED_DIR}/${MIRROR_REGISTRY_CA_FILE_PREFIX}.crt"
if [[ ! -s "${cert}" ]]; then
  echo "Mirror registry CA ${cert} is missing or empty; run hypershift-mirror-registry-ca-generate first" >&2
  exit 1
fi

domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
if [[ -z "${domain}" ]]; then
  echo "Could not read the ingress domain of the management cluster" >&2
  exit 1
fi
host="${MIRROR_REGISTRY_ROUTE_HOST_PREFIX}.${domain}"

# The HyperShift operator init container concatenates every value of this
# ConfigMap into the trust bundle it uses and copies into each control plane
# namespace. The key is the registry hostname, as image.config expects.
oc create configmap "${MIRROR_REGISTRY_CA_CONFIGMAP}" -n openshift-config \
  --from-file="${host}=${cert}" --dry-run=client -o yaml | oc apply -f -

# additionalTrustedCA is an object reference, not a list.
oc patch image.config.openshift.io/cluster --type=merge \
  -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${MIRROR_REGISTRY_CA_CONFIGMAP}\"}}}"

echo "image.config.openshift.io/cluster now trusts the mirror registry CA for ${host}:"
oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA}{"\n"}'
