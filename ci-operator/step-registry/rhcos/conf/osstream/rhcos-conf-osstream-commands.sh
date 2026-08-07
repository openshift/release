#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Info output
echo "Info: rhcos-conf-osstream running, OSSTREAM='${OSSTREAM:-<unset>}', OS_IMAGE_STREAM_MCP_MASTER='${OS_IMAGE_STREAM_MCP_MASTER:-<unset>}', OS_IMAGE_STREAM_MCP_WORKER='${OS_IMAGE_STREAM_MCP_WORKER:-<unset>}'"

# Validation that SHARED_DIR exists
if [[ ! -d "${SHARED_DIR}" ]]; then
  echo "Error: SHARED_DIR not set or doesn't exist"
  exit 1
fi

# Resolve the effective stream for each pool:
# Per-pool override takes precedence, then falls back to OSSTREAM
MASTER_STREAM="${OS_IMAGE_STREAM_MCP_MASTER:-${OSSTREAM:-}}"
WORKER_STREAM="${OS_IMAGE_STREAM_MCP_WORKER:-${OSSTREAM:-}}"

# If neither pool has a stream configured, skip
if [[ -z "${MASTER_STREAM}" && -z "${WORKER_STREAM}" ]]; then
  echo "No OS Image Stream configured for any pool, skipping MachineConfigPool osImageStream configuration"
  exit 0
fi

# Generate master MCP manifest if stream is configured
if [[ -n "${MASTER_STREAM}" ]]; then
  echo "Configuring the master MCP for ${MASTER_STREAM} osImageStream"
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
    name: ${MASTER_STREAM}

EOF
fi

# Generate worker MCP manifest if stream is configured
if [[ -n "${WORKER_STREAM}" ]]; then
  echo "Configuring the worker MCP for ${WORKER_STREAM} osImageStream"
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
    name: ${WORKER_STREAM}

EOF
fi
