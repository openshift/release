#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************  assisted equinix setup command ************"

~/fix_uid.sh

cd "${ANSIBLE_PLAYBOOK_DIRECTORY}"
ansible-playbook --extra-vars "@vars/ci.yml" \
                 --extra-vars "@vars/ci_equinix_infrastucture.yml" \
                 --extra-vars "${ANSIBLE_EXTRA_VARS}"
                 "${ANSIBLE_PLAYBOOK_CREATE_INFRA}"
