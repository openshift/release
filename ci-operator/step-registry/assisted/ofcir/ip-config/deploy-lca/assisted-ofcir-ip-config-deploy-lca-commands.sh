#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config-deploy-lca command ************"

export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"

ansible-playbook "$(dirname "$0")/assisted-ofcir-ip-config-deploy-lca-playbook.yaml" -i "${SHARED_DIR}/inventory"
