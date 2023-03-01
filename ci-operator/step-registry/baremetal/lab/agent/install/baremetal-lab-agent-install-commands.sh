#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Building SSHOPTS"

SSHOPTS=(-o 'ConnectTimeout=5'
-o 'StrictHostKeyChecking=no'
-o 'UserKnownHostsFile=/dev/null'
-o 'ServerAliveInterval=90'
-o LogLevel=ERROR
-i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Executing Ansible playbook using inventory file from /var/builds/${NAMESPACE}/"

echo "Inject variables into /var/builds/${NAMESPACE}/agent-install-inventory"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
cat <<OOO >> /var/builds/${NAMESPACE}/agent-install-inventory
DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}
IP_STACK=${IP_STACK}
CLUSTER_NAME=agent${DEPLOYMENT_TYPE}
DISCONNECTED=${DISCONNECTED}
PROXY=${PROXY}
FIPS=${FIPS}
RELEASE_IMAGE=${RELEASE_IMAGE}
AUX_HOST=${AUX_HOST}
OOO
EOF

echo "Run playbook"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
cd /root/workdir/agent-bm-deployments/
ansible-playbook -i /var/builds/${NAMESPACE}/agent-install-inventory install.yaml
./openshift-install agent wait-for bootstrap-complete
./openshift-install agent wait-for install-complete
EOF
