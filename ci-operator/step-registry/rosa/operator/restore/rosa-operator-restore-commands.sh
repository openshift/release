#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

HO_DEPLOY="operator"
HO_NS="hypershift"

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
JOB_ID="${JOB_NAME:-unknown}-${BUILD_ID:-unknown}"

lock_name() {
  echo "operator-deploy-lock"
}

pull_secret_name() {
  echo "ci-registry-pull-operator"
}

cleanup_pull_secret() {
  local pull_secret="${1}"
  KUBECONFIG="${MC_KUBECONFIG}" oc secrets unlink "${HO_DEPLOY}" "${pull_secret}" -n "${HO_NS}" 2>/dev/null || true
  KUBECONFIG="${MC_KUBECONFIG}" oc delete secret "${pull_secret}" -n "${HO_NS}" --ignore-not-found
}

if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "No MC kubeconfig found, skipping restore"
  exit 0
fi

LOCK_NAME=$(lock_name)
PULL_SECRET=$(pull_secret_name)

IMAGE_FILE="${SHARED_DIR}/operator-original-image"

# If the state file the deploy step should have written is missing, either this job skipped
# the deployment (no openshift/hypershift PR) or it died before completing. Only touch the
# shared MC state when this job owns the lock, otherwise a skipped run could delete the pull
# secret an overlapping PR run is actively using on the same management cluster.
if [[ ! -f "${IMAGE_FILE}" ]]; then
  LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${HO_NS}" \
    -o jsonpath='{.data.job}' 2>/dev/null || true)
  if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
    echo "Deploy state file missing but this job owns the lock; cleaning up partial deploy."
    cleanup_pull_secret "${PULL_SECRET}"
    echo "Releasing orphaned lock owned by this job"
    KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${HO_NS}" --ignore-not-found
  else
    echo "Deploy was skipped or not owned by this job (lock owner: ${LOCK_OWNER:-none}); nothing to restore."
  fi
  exit 0
fi

# Restore the original HyperShift operator container image.
ORIGINAL_IMAGE=$(cat "${IMAGE_FILE}")
echo "Restoring HyperShift operator to original image: ${ORIGINAL_IMAGE}"
KUBECONFIG="${MC_KUBECONFIG}" oc set image "deployment/${HO_DEPLOY}" -n "${HO_NS}" \
  "${HO_DEPLOY}=${ORIGINAL_IMAGE}"

# Remove the CI pull secret from the deployment's imagePullSecrets.
UPDATED_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" -o json \
  | jq -c '[.spec.template.spec.imagePullSecrets // [] | .[] | select(.name != "'"${PULL_SECRET}"'")]')
KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${UPDATED_SECRETS}}}}}" 2>/dev/null || true

# Unlink and remove the CI registry pull secret.
cleanup_pull_secret "${PULL_SECRET}"

# Wait for the HyperShift operator deployment to finish rolling back.
echo "Waiting for HyperShift operator deployment rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status "deployment/${HO_DEPLOY}" -n "${HO_NS}" --timeout=300s

DEPLOYED=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="operator")].image}')
echo "HyperShift operator image after restore: ${DEPLOYED}"

# Release the lock, verifying ownership before deleting.
LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${HO_NS}" \
  -o jsonpath='{.data.job}' 2>/dev/null || true)
if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
  KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${HO_NS}" --ignore-not-found
  echo "Released lock (${LOCK_NAME})"
else
  echo "Lock (${LOCK_NAME}) not owned by this job (owner: ${LOCK_OWNER}), skipping delete"
fi

echo "HyperShift operator restored successfully"
