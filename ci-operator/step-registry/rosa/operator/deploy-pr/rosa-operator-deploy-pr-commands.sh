#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# The HyperShift operator deployment that both modes target.
# ho mode:  patches its container image directly.
# cpo mode: patches its --control-plane-operator-image arg so new HCPs use the PR image.
HO_DEPLOY="operator"
HO_NS="hypershift"

LOCK_ACQUIRED=""
MC_KUBECONFIG=""

lock_name() {
  echo "${OPERATOR_TYPE}-deploy-lock"
}

pull_secret_name() {
  echo "ci-registry-pull-${OPERATOR_TYPE}"
}

cleanup() {
  local children
  children=$(jobs -p) || true
  if [[ -n "${children}" ]]; then
    kill ${children} && wait
  fi
  local lname
  lname=$(lock_name)
  if [[ -n "${LOCK_ACQUIRED}" && -n "${MC_KUBECONFIG}" && -f "${MC_KUBECONFIG}" ]]; then
    LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${lname}" -n "${HO_NS}" \
      -o jsonpath='{.data.job}' 2>/dev/null || true)
    if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
      echo "Releasing lock during cleanup..."
      KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${lname}" -n "${HO_NS}" --ignore-not-found 2>/dev/null || true
    fi
  fi
}
trap 'cleanup; exit 1' TERM INT

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Validate inputs
if [[ "${OPERATOR_TYPE}" != "ho" && "${OPERATOR_TYPE}" != "cpo" ]]; then
  echo "OPERATOR_TYPE must be 'ho' or 'cpo', got: '${OPERATOR_TYPE}'"
  exit 1
fi

if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
  echo "OPERATOR_IMAGE is required (injected via dependencies)"
  exit 1
fi

if [[ -z "${CLUSTER_SECTOR:-}" ]]; then
  echo "CLUSTER_SECTOR is required"
  exit 1
fi

echo "OPERATOR_TYPE: ${OPERATOR_TYPE}"
echo "PR-built image: ${OPERATOR_IMAGE}"

# Log in to OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# Resolve the management cluster from the sector via OSDFM API
echo "Looking up management cluster for sector '${CLUSTER_SECTOR}' in region '${REGION}'..."
MC_CLUSTER_ID=""
for status in ready maintenance; do
  MC_CLUSTER_ID=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters \
    --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${REGION}' and status in ('${status}')" \
    | jq -r '.items[0].cluster_management_reference.cluster_id // empty')
  if [[ -n "${MC_CLUSTER_ID}" ]]; then
    echo "Found MC with status '${status}'"
    break
  fi
done

if [[ -z "${MC_CLUSTER_ID}" ]]; then
  echo "No management cluster found for sector '${CLUSTER_SECTOR}' in region '${REGION}'"
  exit 1
fi

MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}" | jq -r .name)
echo "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

# Get MC kubeconfig
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG}"
echo "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
echo "${MC_CLUSTER_ID}" > "${SHARED_DIR}/mc-cluster-id"

# Acquire a per-operator-type lock to prevent concurrent deployments
LOCK_NAME=$(lock_name)
LOCK_NS="${HO_NS}"
JOB_ID="${JOB_NAME:-unknown}-${BUILD_ID:-unknown}"

LOCK_JSON=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${LOCK_NS}" -o json 2>/dev/null || echo "")
EXISTING_LOCK=$(echo "${LOCK_JSON}" | jq -r '.data.job // empty' 2>/dev/null || true)
if [[ -n "${EXISTING_LOCK}" ]]; then
  LOCK_TIME=$(echo "${LOCK_JSON}" | jq -r '.data.acquired // empty' 2>/dev/null || true)
  LOCK_UID=$(echo "${LOCK_JSON}" | jq -r '.metadata.uid // empty' 2>/dev/null || true)
  if [[ -n "${LOCK_TIME}" ]]; then
    LOCK_EPOCH=$(date -u -d "${LOCK_TIME}" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date -u +%s)
    LOCK_AGE=$(( NOW_EPOCH - LOCK_EPOCH ))
    if [[ ${LOCK_AGE} -gt 14400 ]]; then
      echo "Lock is stale (${LOCK_AGE}s old, >4h). Evicting: ${EXISTING_LOCK}"
      if ! KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${LOCK_NS}" --preconditions="uid=${LOCK_UID}"; then
        echo "Failed to evict stale lock (may have been replaced by another job)"
        exit 1
      fi
    else
      echo "Locked by another job: ${EXISTING_LOCK} (acquired: ${LOCK_TIME}, age: ${LOCK_AGE}s)"
      echo "Cannot deploy PR-built ${OPERATOR_TYPE} while another job holds the lock."
      exit 1
    fi
  else
    echo "Locked by another job: ${EXISTING_LOCK} (no timestamp)"
    exit 1
  fi
fi

if ! KUBECONFIG="${MC_KUBECONFIG}" oc create configmap "${LOCK_NAME}" -n "${LOCK_NS}" \
  --from-literal=job="${JOB_ID}" \
  --from-literal=acquired="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=image="${OPERATOR_IMAGE}"; then
  echo "Failed to acquire lock — another job may have acquired it concurrently"
  exit 1
fi
LOCK_ACQUIRED="true"
echo "Acquired lock (${LOCK_NAME}): ${JOB_ID}"

# Create a CI registry pull secret on the MC so the HyperShift operator deployment
# can pull the PR-built image from registry.ci.openshift.org.
CI_REGISTRY=$(echo "${OPERATOR_IMAGE}" | cut -d'/' -f1)
PULL_SECRET=$(pull_secret_name)
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBECONFIG="${MC_KUBECONFIG}" oc create secret docker-registry "${PULL_SECRET}" \
  --docker-server="${CI_REGISTRY}" \
  --docker-username=serviceaccount \
  --docker-password="${SA_TOKEN}" \
  -n "${HO_NS}" \
  --dry-run=client -o yaml | KUBECONFIG="${MC_KUBECONFIG}" oc apply -f -
echo "Created CI registry pull secret '${PULL_SECRET}' on MC"

KUBECONFIG="${MC_KUBECONFIG}" oc secrets link "${HO_DEPLOY}" "${PULL_SECRET}" --for=pull -n "${HO_NS}" 2>/dev/null || true

if [[ "${OPERATOR_TYPE}" == "ho" ]]; then
  # Save the current HyperShift operator image so the restore step can roll back.
  ORIGINAL_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="operator")].image}')
  echo "${ORIGINAL_IMAGE}" > "${SHARED_DIR}/operator-original-image"
  echo "Current HyperShift operator image: ${ORIGINAL_IMAGE}"

  # Replace the HyperShift operator image with the PR build.
  KUBECONFIG="${MC_KUBECONFIG}" oc set image "deployment/${HO_DEPLOY}" -n "${HO_NS}" \
    "${HO_DEPLOY}=${OPERATOR_IMAGE}"

  # Ensure the pull secret is in the deployment's imagePullSecrets.
  EXISTING_PULL_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" \
    -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null || echo "")
  if ! echo " ${EXISTING_PULL_SECRETS} " | grep -q " ${PULL_SECRET} "; then
    if [[ -z "${EXISTING_PULL_SECRETS}" ]]; then
      KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" \
        --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"'"${PULL_SECRET}"'"}]}]'
    else
      KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" \
        --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets/-","value":{"name":"'"${PULL_SECRET}"'"}}]'
    fi
  fi

elif [[ "${OPERATOR_TYPE}" == "cpo" ]]; then
  # Save the current HyperShift operator deployment args so the restore step can roll back.
  # The CPO override is done by injecting --control-plane-operator-image into the HO deployment;
  # the HO then passes this image to all newly provisioned hosted control planes.
  # Use -o json | jq rather than -o jsonpath so that a missing args field (jsonpath
  # emits nothing, not "[]") always yields a valid JSON array for the patch below.
  ORIGINAL_ARGS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" -o json \
    | jq -c 'first(.spec.template.spec.containers[] | select(.name == "operator") | (.args // [])) // []')
  echo "${ORIGINAL_ARGS}" > "${SHARED_DIR}/operator-original-args"
  echo "Current HyperShift operator args: ${ORIGINAL_ARGS}"

  # Inject/replace --control-plane-operator-image in the HyperShift operator deployment.
  UPDATED_ARGS=$(echo "${ORIGINAL_ARGS}" | \
    jq -c '[.[] | select(startswith("--control-plane-operator-image=") | not)] + ["--control-plane-operator-image='"${OPERATOR_IMAGE}"'"]')
  # Use --type=strategic so that only the named container's args are updated and
  # other containers or fields in the pod spec are not replaced.
  KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment "${HO_DEPLOY}" -n "${HO_NS}" --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${HO_DEPLOY}\",\"args\":${UPDATED_ARGS}}]}}}}"
fi

# Wait for the HyperShift operator deployment to finish rolling out with the new configuration.
echo "Waiting for HyperShift operator deployment rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status "deployment/${HO_DEPLOY}" -n "${HO_NS}" --timeout=300s

READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment "${HO_DEPLOY}" -n "${HO_NS}" \
  -o jsonpath='{.status.readyReplicas}')
echo "HyperShift operator ready replicas: ${READY_REPLICAS}"

if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  echo "HyperShift operator deployment (${HO_DEPLOY}/${HO_NS}) has no ready replicas after rollout!"
  exit 1
fi

echo "PR-built ${OPERATOR_TYPE} active on ${MC_NAME}"
