#!/usr/bin/env bash

set -euo pipefail
set -x

if [[ ${DYNAMIC_ADDITIONAL_TRUST_BUNDLE_ENABLED} == "false" ]]; then
  echo "SKIP additional trust bundle ....."
  exit 0
fi

#Get controlplane endpoint
if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# === Create a temp working dir ===
echo "Create TLS Cert/Key pairs..." >&2
temp_dir=$(mktemp -d)

# generate CA pair
openssl genrsa -out "$temp_dir"/hc_ca.key 2048 2>/dev/null
openssl req  -sha256 -x509 -new -nodes -key "$temp_dir"/hc_ca.key -days 100000 -out "$temp_dir"/hc_ca.crt -subj "/C=CN/ST=Beijing/L=BJ/O=Hypershift team/OU=Hypershift QE Team/CN=Hosted Cluster CA" 2>/dev/null

cp "$temp_dir"/hc_ca.key "${SHARED_DIR}"/hc_ca.key
cp "$temp_dir"/hc_ca.crt "${SHARED_DIR}"/hc_ca.crt

rm -rf "$temp_dir"

# Make sure the namespace exists where the hc will be created, even if the hc is not created yet
oc get namespace "$HYPERSHIFT_NAMESPACE" >/dev/null 2>&1 || oc create namespace "$HYPERSHIFT_NAMESPACE"

# Create a secret with `ca-bundle.crt` key and the ca crt
oc create configmap "$ADDITIONAL_CA_CONFIGMAP_NAME" -n "$HYPERSHIFT_NAMESPACE" --from-file=ca-bundle.crt="${SHARED_DIR}"/hc_ca.crt

# record the configmap name so that the following steps can read it
echo "$ADDITIONAL_CA_CONFIGMAP_NAME" > "${SHARED_DIR}"/hc_additional_trust_bundle_name
