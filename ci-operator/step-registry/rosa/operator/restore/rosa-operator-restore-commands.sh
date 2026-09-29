#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

HO_DEPLOY="operator"
HO_NS="hypershift"

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
JOB_ID="${JOB_NAME:-unknown}-${BUILD_ID:-unknown}"

lock_name() {
  echo "ho-deploy-lock"
}

pull_secret_name() {
  echo "ci-registry-pull-${OPERATOR_TYPE}"
}

cleanup_pull_secret() {
  local pull_secret="${1}"
  KUBECONFIG="${MC_KUBECONFIG}" oc secrets unlink "${HO_DEPLOY}" "${pull_secret}" -n "${HO_NS}" 2>/dev/null || true
  KUBECONFIG="${MC_KUBECONFIG}" oc delete secret "${pull_secret}" -n "${HO_NS}" --ignore-not-found
}

if [[ "${OPERATOR_TYPE}" != "ho" && "${OPERATOR_TYPE}" != "cpo" ]]; then
  echo "OPERATOR_TYPE must be 'ho' or 'cpo', got: '${OPERATOR_TYPE}'"
  exit 1
fi

if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "No MC kubeconfig found, skipping restore"
  exit 0
fi

LOCK_NAME=$(lock_name)
PULL_SECRET=$(pull_secret_name)

if [[ "${OPERATOR_TYPE}" == "ho" ]]; then
  ORIGINAL_FILE="${SHARED_DIR}/operator-original-image"
  if [[ ! -f "${ORIGINAL_FILE}" ]]; then
    echo "No original image file found; deploy may not have completed."
    cleanup_pull_secret "${PULL_SECRET}"
    LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${HO_NS}" \
      -o jsonpath='{.data.job}' 2>/dev/null || true)
    if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
      echo "Releasing orphaned lock owned by this job"
      KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${HO_NS}" --ignore-not-found
    fi
    exit 0
  fi

  ORIGINAL_IMAGE=$(cat "${ORIGINAL_FILE}")
  echo "Restoring HyperShift operator to original image: ${ORIGINAL_IMAGE}"
  KUBECONFIG="${MC_KUBECONFIG}" oc set image "deployment/${HO_DEPLOY}" -n "${HO_NS}" \
    "${HO_DEPLOY}=${ORIGINAL_IMAGE}"

  # Remove the CI pull secret from the deployment's imagePullSecrets.
  UPDATED_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" -o json \
    | jq -c '[.spec.template.spec.imagePullSecrets // [] | .[] | select(.name != "'"${PULL_SECRET}"'")]')
  KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${UPDATED_SECRETS}}}}}" 2>/dev/null || true

elif [[ "${OPERATOR_TYPE}" == "cpo" ]]; then
  ORIGINAL_FILE="${SHARED_DIR}/operator-original-args"
  if [[ ! -f "${ORIGINAL_FILE}" ]]; then
    echo "No original args file found; deploy may not have completed."
    cleanup_pull_secret "${PULL_SECRET}"
    LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${HO_NS}" \
      -o jsonpath='{.data.job}' 2>/dev/null || true)
    if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
      echo "Releasing orphaned lock owned by this job"
      KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${HO_NS}" --ignore-not-found
    fi
    exit 0
  fi

  ORIGINAL_ARGS=$(cat "${ORIGINAL_FILE}")
  echo "Restoring HyperShift operator deployment args: ${ORIGINAL_ARGS}"
  # Use --type=strategic so that only the named container's args are updated and
  # other containers or fields in the pod spec are not replaced.
  KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${HO_DEPLOY}\",\"args\":${ORIGINAL_ARGS}}]}}}}"
fi

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

echo "${OPERATOR_TYPE} operator restored successfully"
