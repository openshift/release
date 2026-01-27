#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail


echo "Configuring the MCPs for rhel-10 osImageStream"
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
    name: rhel-10

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
    name: rhel-10

EOF
