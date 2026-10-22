#!/bin/bash

set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
MIRROR_PROXY_REGISTRY_QUAY=$(echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6001/g')

echo "Mirror registry host: ${MIRROR_REGISTRY_HOST}"
echo "Quay proxy registry: ${MIRROR_PROXY_REGISTRY_QUAY}"

# --- Add mirror registry auth to cluster pull-secret ---

echo "Adding mirror registry auth to cluster pull-secret"
oc extract secret/pull-secret -n openshift-config --confirm --to /tmp

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a \
  "{\"${MIRROR_PROXY_REGISTRY_QUAY}\": {\"auth\": \"${registry_cred}\"}}" \
  '.auths |= . + $a' /tmp/.dockerconfigjson > /tmp/new-dockerconfigjson
$WAS_TRACING && set -x

oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson
echo "Mirror registry auth added to pull-secret"

# --- Add mirror registry CA to cluster trust ---

echo "Adding mirror registry CA to cluster trust"
QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
REGISTRY_HOST=$(echo "${MIRROR_PROXY_REGISTRY_QUAY}" | cut -d: -f1)

oc create configmap registry-config \
  --from-file="${REGISTRY_HOST}..5000=${QE_ADDITIONAL_CA_FILE}" \
  --from-file="${REGISTRY_HOST}..6001=${QE_ADDITIONAL_CA_FILE}" \
  -n openshift-config

oc patch image.config.openshift.io/cluster \
  --patch '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}' \
  --type=merge
echo "Mirror registry CA configured"

# --- Create ICSP or IDMS+ITMS for quay.io/openshifttest ---

echo "Creating image mirror policy for quay.io/openshifttest"
icsp_num=$(oc get ImageContentSourcePolicy -o name 2>/dev/null | wc -l)
kube_minor=$(oc version -o json | jq -r '.serverVersion.minor' | sed 's/+$//')

if [[ ${icsp_num} -gt 0 || ${kube_minor} -lt 26 ]]; then
  cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: image-policy-mco
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/openshifttest
    source: quay.io/openshifttest
EOF
  echo "ICSP created"
else
  cat <<EOF | oc create -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-policy-mco
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/openshifttest
    source: quay.io/openshifttest
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: image-policy-mco
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/openshifttest
    source: quay.io/openshifttest
EOF
  echo "IDMS and ITMS created"
fi

# --- Wait for MCP to roll out ---

echo "Waiting for MCP worker to apply configuration (up to 20 minutes)"
machine_count=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
elapsed=0
while [[ ${elapsed} -lt 1200 ]]; do
  sleep 20
  elapsed=$((elapsed + 20))
  updated=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
  echo "Waiting ${elapsed}s — updated ${updated}/${machine_count}"
  if [[ "${updated}" == "${machine_count}" ]]; then
    echo "MCP worker updated successfully"
    exit 0
  fi
done

echo "ERROR: MCP worker did not finish updating within 20 minutes"
oc get mcp,node
oc get mcp worker -o yaml
exit 1
