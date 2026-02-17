#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__KMM__REGISTRY_URL="${FA__KMM__REGISTRY_URL:-}"
FA__KMM__REGISTRY_ORG="${FA__KMM__REGISTRY_ORG:-}"
FA__KMM__REGISTRY_REPO="${FA__KMM__REGISTRY_REPO:-gpfs-compat-kmod}"

: 'Configuring KMM Registry for Kernel Module Management...'

if [[ -n "$FA__KMM__REGISTRY_ORG" ]]; then
  finalRegistryUrl="${FA__KMM__REGISTRY_URL:-quay.io}"
  fullRepo="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"
  : "Using external registry: ${finalRegistryUrl}/${fullRepo}"
else
  finalRegistryUrl="image-registry.openshift-image-registry.svc:5000"
  fullRepo="ibm-spectrum-scale/${FA__KMM__REGISTRY_REPO}"
  : "Using internal OpenShift registry: ${finalRegistryUrl}/${fullRepo}"
fi

: "Creating kmm-image-config in ${FA__NAMESPACE}..."
oc create configmap kmm-image-config \
  -n "${FA__NAMESPACE}" \
  --from-literal=kmm_image_registry_url="${finalRegistryUrl}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -

if ! oc get configmap kmm-image-config -n "${FA__NAMESPACE}" >/dev/null; then
  : "Failed to create kmm-image-config in ${FA__NAMESPACE}"
  exit 1
fi

: "kmm-image-config created in ${FA__NAMESPACE}"

: 'Creating kmm-image-config in ibm-spectrum-scale-operator namespace...'
oc create configmap kmm-image-config \
  -n ibm-spectrum-scale-operator \
  --from-literal=kmm_image_registry_url="${finalRegistryUrl}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -

if ! oc get configmap kmm-image-config -n ibm-spectrum-scale-operator >/dev/null; then
  : 'Failed to create kmm-image-config in ibm-spectrum-scale-operator'
  exit 1
fi

: 'kmm-image-config created in ibm-spectrum-scale-operator'

: 'KMM Registry configuration complete'
: "  Namespaces: ${FA__NAMESPACE}, ibm-spectrum-scale-operator"
: "  Registry: ${finalRegistryUrl}/${fullRepo}"

true
