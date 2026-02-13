#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__KMM__REGISTRY_URL="${FA__KMM__REGISTRY_URL:-}"
FA__KMM__REGISTRY_ORG="${FA__KMM__REGISTRY_ORG:-}"
FA__KMM__REGISTRY_REPO="${FA__KMM__REGISTRY_REPO:-gpfs-compat-kmod}"

: 'Configuring KMM Registry for Kernel Module Management...'

if [[ -n "$FA__KMM__REGISTRY_ORG" ]]; then
  FINAL_REGISTRY_URL="${FA__KMM__REGISTRY_URL:-quay.io}"
  FULL_REPO="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"
  : "Using external registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
else
  FINAL_REGISTRY_URL="image-registry.openshift-image-registry.svc:5000"
  FULL_REPO="ibm-spectrum-scale/${FA__KMM__REGISTRY_REPO}"
  : "Using internal OpenShift registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
fi

: "Creating kmm-image-config in ${FA__NAMESPACE}..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ${FA__NAMESPACE}
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF

if ! oc get configmap kmm-image-config -n "${FA__NAMESPACE}" >/dev/null; then
  : "Failed to create kmm-image-config in ${FA__NAMESPACE}"
  exit 1
fi

: "kmm-image-config created in ${FA__NAMESPACE}"

: 'Creating kmm-image-config in ibm-spectrum-scale-operator namespace...'

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ibm-spectrum-scale-operator
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF

if ! oc get configmap kmm-image-config -n ibm-spectrum-scale-operator >/dev/null; then
  : 'Failed to create kmm-image-config in ibm-spectrum-scale-operator'
  exit 1
fi

: 'kmm-image-config created in ibm-spectrum-scale-operator'

: 'KMM Registry configuration complete'
: "  Namespaces: ${FA__NAMESPACE}, ibm-spectrum-scale-operator"
: "  Registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
