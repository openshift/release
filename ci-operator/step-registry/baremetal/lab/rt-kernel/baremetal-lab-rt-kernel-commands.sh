#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${RT_ENABLED:-false}" != "true" ]; then
  echo "Real time kernel is not enabled. Skipping..."
  exit 0
fi

if [ "${BOOTSTRAP_IN_PLACE:-false}" == "true" ]; then
  role="master"
else
  role="worker"
fi

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

cat <<EOF > "${SHARED_DIR}/manifest_${role}_rt_kernel.yml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: realtime-${role}
spec:
  kernelType: realtime
EOF

echo "Created manifest file to enable RT kernel for role: ${role}..."
