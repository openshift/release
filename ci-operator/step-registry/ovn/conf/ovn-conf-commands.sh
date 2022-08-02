#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

YQ_DOWNLOAD_URL='https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64'
YQ_SHA512_SUM='c767db10b0d979d4343fca39032e5aca1d106a4343732f80366a0277c6a55dbfad081f0ccdcf5d35fc2ed047aa6f617aa57599fcddc4b359dbf293f2e436256d'

curl -LsS "$YQ_DOWNLOAD_URL" \
  | tee /tmp/yq \
  | sha512sum -c <(printf '%s -' "$YQ_SHA512_SUM")
chmod +x /tmp/yq

touch "${SHARED_DIR}/install-config.yaml"
/tmp/yq w -i "${SHARED_DIR}/install-config.yaml" 'networking.networkType' OVNKubernetes

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret"

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
