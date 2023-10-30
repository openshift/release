#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${ETCD_ON_LOCAL_DISK}" == "true" ]] && [[ "${USE_RAMFS}" == "true" ]]; then
    echo "ERROR: ETCD_ON_LOCAL_DISK is set to true and USE_RAMFS is set to true, the configuration is conflicting."
    exit 1
fi

if [[ "${ETCD_ON_LOCAL_DISK}" == "false" ]]; then
    echo "INFO: ETCD_ON_LOCAL_DISK is set to false, skipping etcd on local disk configuration"
    exit 0
fi

if [[ "${USE_RAMFS}" == "true" ]]; then
    echo "INFO: USE_RAMFS is set to true, skipping etcd on local disk configuration"
    exit 0
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

oc replace -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-var-lib-etcd
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Mount /dev/vdb to /var/lib/etcd
          Before=local-fs.target
          Requires=systemd-mkfs@dev-vdb.service
          After=systemd-mkfs@dev-vdb.service var.mount

          [Mount]
          What=/dev/vdb
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
        enabled: true
        name: var-lib-etcd.mount
EOF

echo "INFO: etcd on local disk configuration complete"
