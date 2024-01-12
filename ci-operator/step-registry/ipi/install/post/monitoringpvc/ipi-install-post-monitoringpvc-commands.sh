#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail


if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Every cluster that can should have a PV for prometheus data so that data is preserved
# across reschedules of pods.

if test false = "${PERSISTENT_MONITORING}"
then
	echo "Nothing to do with PERSISTENT_MONITORING='${PERSISTENT_MONITORING}'"
	exit
fi

yq-go --version

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

CONFIG_CONTENTS="$(yq-go r ${CONFIG} 'data."config.yaml"')"
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

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | yq-go m - "${PATCH}")"
yq-go w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${CONFIG}"

oc apply -f "${CONFIG}"
