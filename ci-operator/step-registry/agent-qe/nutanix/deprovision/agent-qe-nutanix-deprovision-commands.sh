#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source "${SHARED_DIR}/nutanix_context.sh"

export HOME=/output
cd ansible-files
ansible-playbook nutanix_deprovision_vm.yml