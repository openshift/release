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
spec:
  cpu:
    isolated: "${isolated}"
    reserved: "${reserved}"
  nodeSelector:
    node-role.kubernetes.io/${role}: ''
EOL
}

performance_profile "master" "${RESERVED_CORES}" "${ISOLATED_CORES}"
performance_profile "worker" "${RESERVED_CORES}" "${ISOLATED_CORES}"

