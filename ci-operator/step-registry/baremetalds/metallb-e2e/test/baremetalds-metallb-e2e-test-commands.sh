#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds metallb e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Copying metallb directory"
scp "${SSHOPTS[@]}" -r /go/src/github.com/openshift/metallb "root@${IP}:/root/dev-scripts/metallb/"

# Inject additional variables directly.
run_e2e_command="make -C /root/dev-scripts/metallb run_e2e"
if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${E2E_TESTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      run_e2e_command="${run_e2e_command} ${var}"
    fi
  done
fi

ssh "${SSHOPTS[@]}" "root@${IP}" ${run_e2e_command}
