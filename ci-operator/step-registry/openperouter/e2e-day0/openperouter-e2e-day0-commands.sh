#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter day0 e2e test ************"

echo "DEPLOYMENT_MODE: ${DEPLOYMENT_MODE:-standard}"
echo "DATAPLANE: ${DATAPLANE:-kernel}"

# SHARED_DIR is the CI-provided workspace shared by all steps in the workflow.
# The ofcir-acquire step writes packet-conf.sh there; it defines the leased
# host's IP and SSHOPTS and verifies root SSH access.
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Copying OpenPERouter E2E source to remote host"
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" \
  "mkdir -p /root/openperouter && tar -C /root/openperouter -xzf -"

echo "### Running day0 e2e tests on remote host"
set +e
ssh "${SSHOPTS[@]}" "root@${IP}" \
  DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-standard}" \
  DATAPLANE="${DATAPLANE:-kernel}" \
  bash /dev/stdin << 'RUNTESTS'
set -xeo pipefail

# TODO: day0 e2e test commands (TBD). The cluster deployed by the
# openperouter-caas workflow's setup step is reachable via the kubeconfig
# that step stores on the host.
echo "DEPLOYMENT_MODE: ${DEPLOYMENT_MODE:-standard}"
echo "DATAPLANE: ${DATAPLANE:-kernel}"
echo "day0 e2e test placeholder"
RUNTESTS

test_rc="$?"

echo "### Copying e2e test artifacts back from remote host"
scp "${SSHOPTS[@]}" -r "root@${IP}:/tmp/kind_logs" "${ARTIFACT_DIR}/openperouter-e2e-day0-logs" || true

exit "${test_rc}"
