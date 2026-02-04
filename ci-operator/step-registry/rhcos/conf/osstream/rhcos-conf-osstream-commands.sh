#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Info output
echo "Info: rhcos-conf-osstream running, OSSTREAM='${OSSTREAM:-<unset>}'"

# Validation that SHARED_DIR exists
if [[ ! -d "${SHARED_DIR}" ]]; then
  echo "Error: SHARED_DIR not set or doesn't exist"
  exit 1
fi

# Check if OSSTREAM is set and validate it
if [[ -z "${OSSTREAM:-}" ]]; then
  echo "OSSTREAM is not set, skipping MachineConfigPool osImageStream configuration"
  exit 0
fi

if [[ "${OSSTREAM}" != "rhel-9" && "${OSSTREAM}" != "rhel-10" ]]; then
  echo "Error: OSSTREAM must be either 'rhel-9' or 'rhel-10', got: '${OSSTREAM}'"
  exit 1
fi

echo "Configuring the MCPs for ${OSSTREAM} osImageStream"
# these haven't changed in six years so lets assume for now they're stable
# source https://github.com/openshift/machine-config-operator/tree/main/manifests
cat > "${SHARED_DIR}/manifest_master.machineconfigpool.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: master
  labels:
    "operator.machineconfiguration.openshift.io/required-for-upgrade": ""
    "machineconfiguration.openshift.io/mco-built-in": ""
    "pools.operator.machineconfiguration.openshift.io/master": ""
spec:
  machineConfigSelector:
    matchLabels:
      "machineconfiguration.openshift.io/role": "master"
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/master: ""
  osImageStream:
    name: ${OSSTREAM}

EOF

cat > "${SHARED_DIR}/manifest_worker.machineconfigpool.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: worker
  labels:
    "machineconfiguration.openshift.io/mco-built-in": ""
    "pools.operator.machineconfiguration.openshift.io/worker": ""
spec:
  machineConfigSelector:
    matchLabels:
      "machineconfiguration.openshift.io/role": "worker"
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  osImageStream:
    name: ${OSSTREAM}

EOF
