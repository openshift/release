#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


RELEASE_IMAGE=$(oc adm release info --registry-config "${CLUSTER_PROFILE_DIR}/pull-secret" "${RELEASE_IMAGE_LATEST}" -o json|jq -r '.metadata.version')

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=INFO
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
cp "/root/workdir/agent-bm-deployments/prow_${DEPLOYMENT_TYPE}" /root/workdir/agent-bm-deployments/prow_inventory
cat <<OOO >> /root/workdir/agent-bm-deployments/prow_inventory
DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}
IP_STACK=${IP_STACK}
CLUSTER_NAME=agent${DEPLOYMENT_TYPE}
DISCONNECTED=${DISCONNECTED}
PROXY=${PROXY}
FIPS=${FIPS}
RELEASE_IMAGE=registry.ci.openshift.org/ocp/release:${RELEASE_IMAGE}
OOO
cd /root/workdir/agent-bm-deployments/
ansible-playbook -i prow_inventory install.yaml
./openshift-install agent wait-for bootstrap-complete
./openshift-install agent wait-for install-complete
EOF
