#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Every cluster that can should have a PV for prometheus data so that data is preserved
# across reschedules of pods.

if test false = "${PERSISTENT_MONITORING}"
then
	echo "Nothing to do with PERSISTENT_MONITORING='${PERSISTENT_MONITORING}'"
	exit
fi

# Use yq to create cluster monitoring config, as other steps may adjust it
YQ_URI=https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64
YQ_HASH=e70e482e7ddb9cf83b52f5e83b694a19e3aaf36acf6b82512cbe66e41d569201
echo "${YQ_HASH} -" > /tmp/sum.txt
if ! curl -Ls "${YQ_URI}" | tee /tmp/yq | sha256sum -c /tmp/sum.txt >/dev/null 2>/dev/null; then
  echo "Expected file at ${YQ_URI} to have checksum ${YQ_HASH} but instead got $(sha256sum </tmp/yq | cut -d' ' -f1)"
  strings /tmp/yq
  exit 1
fi
echo "Downloaded yq; sha256 checksum matches expected ${YQ_HASH}."
chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
PATCH="${SHARED_DIR}/cluster-monitoring-config.yaml.patch"

if test -e "${CONFIG}"
then
  echo "initial configuration:"
  cat "${CONFIG}"
else
  # Create config if empty
  touch "${CONFIG}"
fi

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


# Alibaba requires PVCs to be >= 20GB
STORAGE="20Gi"

# On top of setting up persistent storage for the platform Prometheus, we are
# also annotating the PVCs so that the cluster-monitoring-operator can delete
# the PVC if needed to prevent single point of failure. This is required to
# prevent the operator from reporting Upgradeable=false.
cat >> "${PATCH}" << EOF
prometheusK8s:
  volumeClaimTemplate:
    metadata:
      name: prometheus-data
      annotations:
        openshift.io/cluster-monitoring-drop-pvc: "yes"
    spec:
      resources:
        requests:
          storage: ${STORAGE}
EOF

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | /tmp/yq m - "${PATCH}")"
/tmp/yq w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${CONFIG}"
