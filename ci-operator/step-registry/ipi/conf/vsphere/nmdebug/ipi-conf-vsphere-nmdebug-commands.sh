#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi


NMDEBUG_MANIFEST="${SHARED_DIR}/manifest_nmdebug.yaml"

echo "$(date -u --rfc-3339=seconds) - adding NetworkManager debug Machine Config ${NMDEBUG_MANIFEST}"

cat >> ${NMDEBUG_MANIFEST} << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-nm-trace-logging
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,W2xvZ2dpbmddCmRvbWFpbnM9QUxMOlRSQUNFCg==
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/99-nm-trace-logging.conf
EOF
