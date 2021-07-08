#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds metallb e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Copying metallb directory"
scp "${SSHOPTS[@]}" -r /go/src/github.com/openshift/metallb "root@${IP}:/root/dev-scripts/metallb/"
ssh "${SSHOPTS[@]}" "root@${IP}" make -C /root/dev-scripts/metallb run_e2e
