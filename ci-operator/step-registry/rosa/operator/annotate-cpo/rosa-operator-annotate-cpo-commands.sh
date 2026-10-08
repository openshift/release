#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Stamps the PR-built control-plane-operator (CPO) image onto the HostedCluster under test via
# the hypershift.openshift.io/control-plane-operator-image annotation, which is the highest
# precedence source the HyperShift operator consults when choosing a CPO image. Setting only the
# operator's --control-plane-operator-image flag (as rosa-operator-deploy-pr does) never takes
# effect, because the CPO baked into the release image outranks that flag. See ROSAENG-74212.
#
# This step runs immediately after the cluster-create ref and before the cluster readiness checks,
# so the HyperShift operator rolls the PR CPO onto the control plane while the cluster is still
# installing. That is what lets the job catch install/bootstrap regressions, which is most of what
# CPO PRs change.
#
# The CPO image lives on the CI registry, so its credentials are merged into the HostedCluster
# pull secret first; the operator resolves and the control plane pulls the CPO using that secret
# (HyperShift syncs it into the control plane namespace), and OCM's pull secret has no CI creds.
# After annotating, the step waits for the operator to actually roll the control-plane-operator
# deployment to the PR image and become healthy, so a CPO that never runs cannot pass silently.

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Only override the CPO when a PR is under test. Without one (periodic, gangway, or manual runs),
# ci-operator builds the hypershift image from the branch HEAD, and replacing the payload CPO with
# it would mean no longer testing the release payload. /payload-job runs are periodics, so JOB_TYPE
# does not distinguish them; inspect JOB_SPEC for pull refs instead.
if [[ -z "${JOB_SPEC:-}" ]]; then
  log "JOB_SPEC is unset; assuming no PR under test, keeping the CPO from the release payload"
  exit 0
fi
PULLS=$(echo "${JOB_SPEC}" | jq -r '[.refs] + (.extra_refs // []) | map(select(. != null) | (.pulls // []) | length) | add // 0')
if (( PULLS == 0 )); then
  log "No PR under test; keeping the CPO from the release payload"
  exit 0
fi

# Validate inputs
if [[ -z "${CPO_OPERATOR_IMAGE:-}" ]]; then
  log "CPO_OPERATOR_IMAGE is required (the PR-built control plane operator image, injected via dependencies)"
  exit 1
fi
log "PR-built control plane operator image: ${CPO_OPERATOR_IMAGE}"

# Log into OCM. Disable tracing due to credential handling (secrets must not be
# exposed through expanded xtrace output of the reads or the ocm login arguments).
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  $WAS_TRACING && set -x
  exit 1
fi
$WAS_TRACING && set -x

# Resolve the hosted cluster and the management cluster that actually runs it.
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r '.name')
log "Hosted cluster ID: ${CLUSTER_ID}"
log "Hosted cluster name: ${CLUSTER_NAME}"

MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')
if [[ -z "${MC_NAME}" || "${MC_NAME}" == "null" ]]; then
  log "ERROR: Failed to get management cluster name for cluster ${CLUSTER_ID}"
  exit 1
fi
MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id')
if [[ -z "${MC_CLUSTER_ID}" || "${MC_CLUSTER_ID}" == "null" ]]; then
  log "ERROR: Failed to get management cluster ID for ${MC_NAME}"
  exit 1
fi
log "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

# Fetch the MC kubeconfig (handle credentials without tracing).
MC_KUBECONFIG="${SHARED_DIR}/annotate-mc.kubeconfig"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r '.kubeconfig' > "${MC_KUBECONFIG}"
$WAS_TRACING && set -x
if ! KUBECONFIG="${MC_KUBECONFIG}" oc whoami &>/dev/null; then
  log "ERROR: MC kubeconfig validation failed (oc whoami failed)"
  exit 1
fi

# HC namespace: ocm-<env>-<cluster_id>. The namespace env token is the OCM short name, which
# differs from OCM_LOGIN_ENV: integration -> int (staging and production match verbatim).
case "${OCM_LOGIN_ENV}" in
  integration) NS_ENV="int" ;;
  *)           NS_ENV="${OCM_LOGIN_ENV}" ;;
esac
HC_NAMESPACE="ocm-${NS_ENV}-${CLUSTER_ID}"
log "HostedCluster namespace: ${HC_NAMESPACE}"

# Wait for the HostedCluster CR to appear on the MC (OCM provisions it asynchronously).
START_TIME=$(date +%s)
while true; do
  if KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" &>/dev/null; then
    log "Found HostedCluster '${CLUSTER_NAME}' in ${HC_NAMESPACE}"
    break
  fi
  elapsed=$(( $(date +%s) - START_TIME ))
  if (( elapsed >= HC_APPEAR_TIMEOUT )); then
    log "ERROR: Timed out after ${HC_APPEAR_TIMEOUT}s waiting for HostedCluster '${CLUSTER_NAME}' in ${HC_NAMESPACE}"
    exit 1
  fi
  log "WAITING: HostedCluster '${CLUSTER_NAME}' not present yet (elapsed: ${elapsed}s), retrying in 30s..."
  sleep 30
done

# Merge CI registry credentials into the HostedCluster pull secret so the control plane can pull
# the PR-built CPO image. HyperShift reads spec.pullSecret from the HC namespace and syncs it into
# the control plane namespace, where the CPO deployment uses it to pull.
PS_NAME=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" \
  -o jsonpath='{.spec.pullSecret.name}')
if [[ -z "${PS_NAME}" ]]; then
  log "ERROR: HostedCluster '${CLUSTER_NAME}' has no spec.pullSecret.name"
  exit 1
fi
CI_REGISTRY=$(echo "${CPO_OPERATOR_IMAGE}" | cut -d'/' -f1)
log "Merging CI registry '${CI_REGISTRY}' credentials into pull secret '${PS_NAME}'"

# Disable tracing due to pull-secret and token handling.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CI_AUTH=$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 -w0)
CURRENT_DOCKERCFG=$(KUBECONFIG="${MC_KUBECONFIG}" oc get secret "${PS_NAME}" -n "${HC_NAMESPACE}" \
  -o json | jq -r '.data[".dockerconfigjson"] // empty' | base64 -d)
if [[ -z "${CURRENT_DOCKERCFG}" ]]; then
  log "ERROR: pull secret '${PS_NAME}' has no .dockerconfigjson"
  $WAS_TRACING && set -x
  exit 1
fi
MERGED_DOCKERCFG=$(echo "${CURRENT_DOCKERCFG}" \
  | jq -c --arg reg "${CI_REGISTRY}" --arg auth "${CI_AUTH}" '.auths[$reg] = {auth: $auth}')
MERGED_B64=$(echo -n "${MERGED_DOCKERCFG}" | base64 -w0)
KUBECONFIG="${MC_KUBECONFIG}" oc patch secret "${PS_NAME}" -n "${HC_NAMESPACE}" --type=merge \
  -p "{\"data\":{\".dockerconfigjson\":\"${MERGED_B64}\"}}"
$WAS_TRACING && set -x
log "Merged CI registry credentials into pull secret '${PS_NAME}'"

# Stamp the annotation so the HyperShift operator deploys the PR-built CPO for this cluster.
KUBECONFIG="${MC_KUBECONFIG}" oc annotate hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" \
  "hypershift.openshift.io/control-plane-operator-image=${CPO_OPERATOR_IMAGE}" --overwrite
log "Annotated HostedCluster '${CLUSTER_NAME}' with control-plane-operator-image=${CPO_OPERATOR_IMAGE}"

# Verify the HyperShift operator actually rolls the control plane operator onto the PR image.
# The downstream HC/HCP readiness checks can pass on conditions left True by the install, and a
# crash-looping new CPO pod leaves the old replica serving the deployment, so without this check a
# broken CPO could still produce a green job.
HCP_NAMESPACE="${HC_NAMESPACE}-${CLUSTER_NAME}"
log "Waiting for the control-plane-operator deployment in ${HCP_NAMESPACE} to switch to the PR image..."
ROLLOUT_START=$(date +%s)
while true; do
  CPO_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="control-plane-operator")].image}' 2>/dev/null || true)
  if [[ "${CPO_IMAGE}" == "${CPO_OPERATOR_IMAGE}" ]]; then
    log "control-plane-operator deployment now references the PR image"
    break
  fi
  elapsed=$(( $(date +%s) - ROLLOUT_START ))
  if (( elapsed >= CPO_ROLLOUT_TIMEOUT )); then
    log "ERROR: Timed out after ${CPO_ROLLOUT_TIMEOUT}s waiting for control-plane-operator to use ${CPO_OPERATOR_IMAGE} (current: ${CPO_IMAGE:-<none>})"
    exit 1
  fi
  log "WAITING: control-plane-operator image is '${CPO_IMAGE:-<none>}' (elapsed: ${elapsed}s), retrying in 10s..."
  sleep 10
done

# Confirm the rolled deployment becomes healthy on the PR image (catches a crash-looping CPO).
if ! KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/control-plane-operator -n "${HCP_NAMESPACE}" \
  --timeout="${CPO_ROLLOUT_TIMEOUT}s"; then
  log "ERROR: control-plane-operator rollout did not complete on the PR image"
  exit 1
fi
log "control-plane-operator rollout complete on the PR image"

# Record the applied override only after confirming the PR-built CPO actually runs, so the artifact
# reflects what was really tested.
echo "${CPO_OPERATOR_IMAGE}" > "${SHARED_DIR}/cpo-annotation-image"

log "PR-built control plane operator override applied and verified on ${CLUSTER_NAME}"
