#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Every cluster that can should have a PV for prometheus data so that data is preserved
# across reschedules of pods. This may need to be conditionally disabled in the future
# if certain instance types are used that cannot access persistent volumes.

# Use yq to create cluster monitoring config, as other steps may adjust it
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
PATCH="${SHARED_DIR}/cluster-monitoring-config.yaml.patch"

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
prometheusK8s:
  volumeClaimTemplate:
    metadata:
      name: prometheus-data
    spec:
      resources:
        requests:
          storage: 10Gi
EOF

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | /tmp/yq m - "${PATCH}")"
/tmp/yq w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${CONFIG}"
