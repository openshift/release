#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function performance_profile() {
  role=${1}
  reserved=${2}
  isolated=${3}
cat >"${SHARED_DIR}/manifest_${role}_performance_profile.yaml" <<EOL
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: ${role}-performanceprofile
  namespace: "openshift-cluster-node-tuning-operator"
spec:
  cpu:
    isolated: "${isolated}"
    reserved: "${reserved}"
  nodeSelector:
    node-role.kubernetes.io/${role}: ''
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/${role}: ''
EOL

  oc apply -f "${SHARED_DIR}/manifest_${role}_performance_profile.yaml"
  oc get performanceprofile "${role}-performanceprofile" -n openshift-cluster-node-tuning-operator -oyaml
}

echo "Creating master profile with reserved cores: ${RESERVED_CORES} isolated cores: ${ISOLATED_CORES}"
performance_profile "master" "${RESERVED_CORES}" "${ISOLATED_CORES}"

if [ "$ADD_WORKER_PROFILE" != "false" ]; then
  echo "Creating worker profile with reserved cores: ${RESERVED_CORES} isolated cores: ${ISOLATED_CORES}"
  performance_profile "worker" "${RESERVED_CORES}" "${ISOLATED_CORES}"
fi

echo "$(date -u --rfc-3339=seconds) - All machineconfigs should be updated after rollout..."
until oc wait --for=condition=updated machineconfigpools master --timeout=30m &> /dev/null
do
  echo "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5s
done

