#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/shiftstack-ci-functions.sh"
    source "${SHARED_DIR}/shiftstack-ci-functions.sh"
then
    echo "Warning: failed to find ${SHARED_DIR}/shiftstack-ci-functions.sh!"
    CO_DIR=$(mktemp -d)
    echo "Falling back to local copy in ${CO_DIR}"
    git clone https://github.com/shiftstack/shiftstack-ci.git "${CO_DIR}"
    if test -f "${CO_DIR}/shiftstack-ci-functions.sh"
    then
        source "${CO_DIR}/shiftstack-ci-functions.sh"
    else
        echo "Failed to find ${CO_DIR}/shiftstack-ci-functions.sh!"
    fi
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

VFIO_NOIOMMU=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: 99-vfio-noiommu 
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/modprobe.d/vfio-noiommu.conf
        mode: 0644
        contents:
          source: data:;base64,b3B0aW9ucyB2ZmlvIGVuYWJsZV91bnNhZmVfbm9pb21tdV9tb2RlPTEK
EOF
)
echo "Created \"$VFIO_NOIOMMU\" MachineConfig"

check_mcp_updating 6 20 worker
check_mcp_updated 60 20 worker

echo "MachineConfig was successfully applied to all workers"
