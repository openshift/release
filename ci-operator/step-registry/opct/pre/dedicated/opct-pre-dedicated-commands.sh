#!/bin/bash

#
# Setup the OPCT dedicated node to be used exclisvely for the
# aggregator server and workflow steps (plugin openshift-tests).
# The selector algorith tries to not use the nodes with prometheus
# server, heaviest workloads running in worker nodes, to prevent
# disruptions and total time to setup the environment.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
extract_opct

# setup dedicated node
${OPCT_CLI} adm setup-node --yes

# setup MachineConfigPool to pause upgrades into
# dedicated node (prevent disruptions).
if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
    cat << EOF | oc create -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: opct
spec:
  machineConfigSelector:
    matchExpressions:
    - key: machineconfiguration.openshift.io/role,
      operator: In,
      values: [worker,opct]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/tests: ""
  paused: true
EOF

fi
