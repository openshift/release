#!/bin/bash
set -euo pipefail

if [[ "${ENABLE_USER_WORKLOAD_MONITORING}" != "true" ]]; then
  echo "ENABLE_USER_WORKLOAD_MONITORING is not 'true', nothing to do."
  exit 0
fi

CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
PATCH="${SHARED_DIR}/cluster-monitoring-config.yaml.uwm-patch"

if ! test -e "${CONFIG}"; then
  cat > "${CONFIG}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml:
EOF
fi

cat > "${PATCH}" << EOF
enableUserWorkload: true
EOF

CONFIG_CONTENTS="$(yq-go r "${CONFIG}" 'data."config.yaml"')"
CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | yq-go m - "${PATCH}")"
yq-go w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"

cat > "${SHARED_DIR}/manifest_user-workload-monitoring-config.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    alertmanager:
      enabled: true
EOF
