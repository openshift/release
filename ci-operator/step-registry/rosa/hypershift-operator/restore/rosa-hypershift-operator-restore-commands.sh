#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
JOB_ID="${JOB_NAME:-unknown}-${BUILD_ID:-unknown}"

if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "No MC kubeconfig found, skipping restore"
  exit 0
fi

ORIGINAL_IMAGE_FILE="${SHARED_DIR}/ho-original-image"
if [[ ! -f "${ORIGINAL_IMAGE_FILE}" ]]; then
  echo "No original HO image file found, deploy may not have completed."
  # Release the lock if we own it (deploy failed between lock creation and image save)
  LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift \
    -o jsonpath='{.data.job}' 2>/dev/null || true)
  if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
    echo "Releasing orphaned lock owned by this job"
    KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap ho-deploy-lock -n hypershift --ignore-not-found
  fi
  exit 0
fi

ORIGINAL_IMAGE=$(cat "${ORIGINAL_IMAGE_FILE}")
echo "Restoring HO to original image: ${ORIGINAL_IMAGE}"

# Restore the original HO image
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/operator -n hypershift \
  operator="${ORIGINAL_IMAGE}"

# Remove ci-registry-pull from deployment imagePullSecrets, preserving other entries
UPDATED_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o json \
  | jq -c '[.spec.template.spec.imagePullSecrets // [] | .[] | select(.name != "ci-registry-pull")]')
KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment operator -n hypershift --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${UPDATED_SECRETS}}}}}" 2>/dev/null || true

# Unlink the pull secret from the operator service account
KUBECONFIG="${MC_KUBECONFIG}" oc secrets unlink operator ci-registry-pull -n hypershift 2>/dev/null || true

# Delete the CI registry pull secret
KUBECONFIG="${MC_KUBECONFIG}" oc delete secret ci-registry-pull -n hypershift --ignore-not-found

# Wait for rollout
echo "Waiting for HO rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/operator -n hypershift --timeout=300s

DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Restored HO image: ${DEPLOYED_IMAGE}"

# Release the MC lock
KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap ho-deploy-lock -n hypershift --ignore-not-found
echo "Released MC lock"

echo "HyperShift operator restored successfully"
