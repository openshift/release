#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


nm_config=$(cat <<EOF | base64 -w0
[logging]
level=TRACE
EOF
)

for role in master worker; do
    cat << EOF > "${SHARED_DIR}/${role}-networkmanager-configuration.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: nm-trace-logging
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${nm_config}
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/99-trace-logging.conf
EOF
done

echo "master-networkmanager-configuration.yaml"
echo "---------------------------------------------"
cat "${SHARED_DIR}/master-networkmanager-configuration.yaml"
