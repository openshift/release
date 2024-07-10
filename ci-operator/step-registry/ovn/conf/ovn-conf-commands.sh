#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

touch "${SHARED_DIR}/install-config.yaml"
/tmp/yq w -i "${SHARED_DIR}/install-config.yaml" 'networking.networkType' OVNKubernetes

if [[ ! -z "${GATEWAY_MODE}" ]]; then
  echo "Overriding OVN gateway mode with \"${GATEWAY_MODE}\""
  cat >> "${SHARED_DIR}/manifest_cluster-network-00-gateway-mode.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
    name: gateway-mode-config
    namespace: openshift-network-operator
data:
    mode: "${GATEWAY_MODE}"
immutable: true
EOF
  echo "manifest_cluster-network-00-gateway-mode.yaml"
  echo "---------------------------------------------"
  cat ${SHARED_DIR}/manifest_cluster-network-00-gateway-mode.yaml
fi
