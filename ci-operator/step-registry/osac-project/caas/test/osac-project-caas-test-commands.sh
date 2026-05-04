#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac CaaS test ************"
echo "TEST: ${TEST}"
echo "OSAC_CLUSTER_TEMPLATE: ${OSAC_CLUSTER_TEMPLATE}"

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${TEST}" "${E2E_NAMESPACE}" "${OSAC_CLUSTER_TEMPLATE}" "${OSAC_TEST_INFRA_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

TEST="$1"
E2E_NAMESPACE="$2"
OSAC_CLUSTER_TEMPLATE="$3"
OSAC_TEST_INFRA_IMAGE="$4"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
[[ -z "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found" && exit 1

PULL_SECRET_PATH="/root/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=- > "${PULL_SECRET_PATH}"
ssh-keygen -t rsa -b 2048 -f /tmp/id_rsa -N "" -q

podman run --authfile "${PULL_SECRET_PATH}" --rm --network=host \
  -v "${KUBECONFIG}:/root/.kube/config:z" \
  -v "${PULL_SECRET_PATH}:/tmp/pull-secret.json:z" \
  -v "/tmp/id_rsa.pub:/tmp/id_rsa.pub:z" \
  -e KUBECONFIG=/root/.kube/config \
  -e OSAC_NAMESPACE="${E2E_NAMESPACE}" \
  -e OSAC_CLUSTER_TEMPLATE="${OSAC_CLUSTER_TEMPLATE}" \
  -e OSAC_PULL_SECRET_PATH=/tmp/pull-secret.json \
  -e OSAC_SSH_PUBLIC_KEY_PATH=/tmp/id_rsa.pub \
  "${OSAC_TEST_INFRA_IMAGE}" \
  make test TEST="${TEST}"
REMOTE_EOF
