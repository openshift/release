#!/bin/bash
set +x
set -euo pipefail
umask 077
: "${SHARED_DIR:?}" "${ARTIFACT_DIR:?}"
# 1. Connect to the verified target and read the exact images checked earlier.
# IMG and VALIDATOR_IMG are the variable names consumed by SSP make deploy.
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[[ -s $KUBECONFIG ]] || { echo 'Provisioned kubeconfig is missing' >&2; exit 1; }
export IMG VALIDATOR_IMG
IMG=$(jq -er '.operator' "${SHARED_DIR}/ssp-images.json")
VALIDATOR_IMG=$(jq -er '.validator' "${SHARED_DIR}/ssp-images.json")
export GOFLAGS=
export SKIP_CLEANUP_AFTER_TESTS=true
phase=storage
# Keep a small, non-sensitive result even when setup fails. Retain the dedicated
# cluster for diagnosis; the next API rebuild replaces it. No shared undeploy.
# shellcheck disable=SC2329
finish() {
  local result=$?
  trap - EXIT
  jq -n --arg phase "$phase" --argjson exit_code "$result" \
    '{phase:$phase,exit_code:$exit_code}' > "${ARTIFACT_DIR}/ssp-result.json" || true
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 2. Check the storage prerequisite before installing dependencies.
# Infra supplies a working default provisioner (HPP is supported on s390x).
# Its existence is only a prerequisite; PVC functionality is exercised by tests.
# First select the defaults, then validate their count and provisioning mode.
default_storage=$(oc --request-timeout=30s get storageclasses -o json | jq '
  [.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
    .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")]
')
if ! jq -e 'length == 1' <<< "$default_storage" >/dev/null; then
  echo 'Require exactly one default StorageClass' >&2
  exit 1
fi
if ! jq -e '.[0].provisioner != "kubernetes.io/no-provisioner"' <<< "$default_storage" >/dev/null; then
  echo 'Default StorageClass must support dynamic provisioning' >&2
  exit 1
fi
# 3. Use SSP automation to install KubeVirt/CDI and record observed versions.
phase=dependencies
# Reuse SSP main's dependency selection and installation behavior (latest stable
# KubeVirt/CDI). Do not silently rewrite or override its scripts in the CI job.
./automation/common/deploy-kubevirt-and-cdi.sh
oc --request-timeout=30s get kubevirt kubevirt -n kubevirt -o json | \
  jq '{component:"kubevirt",version:.status.observedKubeVirtVersion}' > "${ARTIFACT_DIR}/kubevirt-version.json"
oc --request-timeout=30s get cdi cdi -o json | \
  jq '{component:"cdi",version:.status.observedVersion}' > "${ARTIFACT_DIR}/cdi-version.json"
# 4. Apply SSP network policy, deploy the checked images and wait for rollout.
# A failed deployment stops the script before functional tests begin.
phase=deploy
KUBECTL=oc ./hack/install-network-policy.sh
make deploy
oc --request-timeout=11m rollout status deployment/ssp-operator -n kubevirt --timeout=10m
# 5. Run the existing SSP suite. Its exit status becomes the step result; the
# EXIT trap records the phase so setup failures can be distinguished from tests.
phase=functest
make functest
phase=complete
