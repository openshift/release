#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-mixed-publish.yaml.patch"

if [[ -z "${APISERVER_PUBLISH_STRATEGY}" ]] && [[ -z "${INGRESS_PUBLISH_STRATEGY}" ]]; then
    echo "ERROR: Mixed publish setting, APISERVER_PUBLISH_STRATEGY and INGRESS_PUBLISH_STRATEGY are both empty!\nPlease specify the operator publishing strategy for mixed publish strategy!"
    exit 1
fi

cat > "${PATCH}" << EOF
publish: Mixed
operatorPublishingStrategy:
EOF

if [[ ! -z "${APISERVER_PUBLISH_STRATEGY}" ]]; then
cat >> "${PATCH}" << EOF
  apiserver: ${APISERVER_PUBLISH_STRATEGY}
EOF
fi

if [[ ! -z "${INGRESS_PUBLISH_STRATEGY}" ]]; then
cat >> "${PATCH}" << EOF
  ingress: ${INGRESS_PUBLISH_STRATEGY}
EOF
fi

echo "APISERVER_PUBLISH_STRATEGY: ${APISERVER_PUBLISH_STRATEGY}"
echo "INGRESS_PUBLISH_STRATEGY: ${INGRESS_PUBLISH_STRATEGY}"
echo "The content of ${PATCH}:"
cat "${PATCH}"

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
