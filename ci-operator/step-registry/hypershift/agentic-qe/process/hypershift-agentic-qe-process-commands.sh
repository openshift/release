#!/bin/bash
set -euo pipefail

echo "=== HyperShift Agentic QE: hold the environment ==="

# Gangway cannot set step parameters directly, so it passes these prefixed
# transport variables through; when set they take precedence.
HOLD_DURATION="${MULTISTAGE_PARAM_OVERRIDE_HOLD_DURATION:-${HOLD_DURATION}}"
CHAI_SHARED_DIR_ACCESS="${MULTISTAGE_PARAM_OVERRIDE_CHAI_SHARED_DIR_ACCESS:-${CHAI_SHARED_DIR_ACCESS}}"

if [[ ! "${HOLD_DURATION}" =~ ^[0-9]+[smh]?$ ]]; then
  echo "ERROR: HOLD_DURATION must be a sleep(1) duration such as 30m or 1h, got '${HOLD_DURATION}'"
  exit 1
fi

# KUBECONFIG points at the management cluster (SHARED_DIR/kubeconfig).
echo "Management cluster: $(oc whoami --show-server)"
echo "HostedCluster: clusters/$(cat "${SHARED_DIR}/cluster-name" 2>/dev/null || echo unknown)"
echo "Hosted cluster: $(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc whoami --show-server 2>/dev/null || echo unknown)"

# create_ignoring_existing <oc create args...>
# A rerun of the same refs reuses this namespace, and with it a grant made by
# an earlier run.
create_ignoring_existing() {
  local output
  if ! output="$(oc create "$@" 2>&1)"; then
    if [[ "${output}" == *AlreadyExists* || "${output}" == *"already exists"* ]]; then
      echo "Already present: $*"
      return 0
    fi
    echo "${output}"
    return 1
  fi
  echo "${output}"
}

if [[ "${CHAI_SHARED_DIR_ACCESS}" == "true" ]]; then
  # Chai Bot reads the kubeconfigs from this test's SHARED_DIR secret with its
  # read-only build-farm identity, which cannot read secrets by itself. Grant it
  # that one secret, in this namespace only; the grant goes away with the
  # namespace. The multi-stage test service account may create roles and
  # bindings here, and holds get on the secret it grants. Like ipi-install-rbac,
  # talk to the build farm with that account: KUBECONFIG is the cluster under test.
  echo "Granting ci/chai-bot-cluster-reader read access to secret ${NAMESPACE}/${JOB_NAME_SAFE}"
  (
    unset KUBECONFIG
    create_ignoring_existing role chai-shared-dir-reader --namespace="${NAMESPACE}" \
      --verb=get --resource=secrets --resource-name="${JOB_NAME_SAFE}"
    create_ignoring_existing rolebinding chai-shared-dir-reader --namespace="${NAMESPACE}" \
      --role=chai-shared-dir-reader --serviceaccount=ci:chai-bot-cluster-reader
  )
fi

echo "Holding the environment for ${HOLD_DURATION}; the post phase tears it down afterwards."
sleep "${HOLD_DURATION}"
echo "Hold ended."
