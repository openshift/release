#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

typeset fullRepo="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"

oc create configmap kmm-image-config \
  -n "${FA__NAMESPACE}" \
  --from-literal=kmm_image_registry_url="${FA__KMM__REGISTRY_URL}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -

oc create configmap kmm-image-config \
  -n ibm-spectrum-scale-operator \
  --from-literal=kmm_image_registry_url="${FA__KMM__REGISTRY_URL}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -

true
