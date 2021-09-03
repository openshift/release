#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Use yq to create cluster monitoring config, as other steps may adjust it
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
PATCH="/tmp/cluster-monitoring-config.yaml.patch"

# Create config if empty
touch "${CONFIG}"
CONFIG_CONTENTS="$(/tmp/yq r ${CONFIG} 'data."config.yaml"')"
if [ -z "${CONFIG_CONTENTS}" ]; then
  cat >> "${CONFIG}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml:
EOF
fi

cat >> "${PATCH}" << EOF
enableUserWorkload: true
EOF

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | /tmp/yq m - "${PATCH}")"
/tmp/yq w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${CONFIG}"
