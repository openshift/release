#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds ingress-node-firewall e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

INGRESS_NODE_FIREWALL_SRC_DIR="/go/src/github.com/openshift/ingress-node-firewall"

echo "### Copying ingress-node-firewall directory"
scp "${SSHOPTS[@]}" -r "${INGRESS_NODE_FIREWALL_SRC_DIR}" "root@${IP}:/root/dev-scripts/"

echo "### deploying ingress-node-firewall through operator"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ingress-node-firewall/openshift-ci/ && ./deploy_ingress_node_firewall.sh"

echo "### running ingress-node-firewall E2E tests"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ingress-node-firewall/openshift-ci/ && ./run_e2e.sh"
