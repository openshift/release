#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Info: ingress-conf-haproxy-version running"
echo "  HAPROXY_VERSION='${HAPROXY_VERSION:-<unset>}'"

if [[ ! -d "${SHARED_DIR:-}" ]]; then
  echo "Error: SHARED_DIR not set or doesn't exist"
  exit 1
fi

if [[ -z "${HAPROXY_VERSION:-}" ]]; then
  echo "Error: HAPROXY_VERSION must be set"
  exit 1
fi

echo "Configuring default IngressController with HAProxy version: ${HAPROXY_VERSION}"

cat > "${SHARED_DIR}/manifest_default-ingresscontroller.yaml" <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  haproxyVersion: "${HAPROXY_VERSION}"
EOF

echo "Wrote IngressController manifest to ${SHARED_DIR}/manifest_default-ingresscontroller.yaml"
cat "${SHARED_DIR}/manifest_default-ingresscontroller.yaml"
