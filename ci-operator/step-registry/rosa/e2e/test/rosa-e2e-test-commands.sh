#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Fixed-enum marker for the setup stage currently in progress, used only to
# attribute an early exit.
#
# The setup below runs under errexit and pipefail, and the OCM lookups discard
# their stderr on purpose so that credentials and API URLs never reach the
# publicly retained Prow log. A failure in one of those pipelines therefore
# aborts the step before the test binary starts and emits nothing at all: the
# log simply stops mid-setup and the container exits non-zero, which is
# indistinguishable from the e2e suite having run and failed.
#
# SETUP_STAGE must only ever be assigned one of the literals listed below -- never
# interpolated data -- so this diagnostic cannot echo captured stderr, command
# lines, environment, credentials or cluster identifiers into the public log.
# Bash discards an EXIT handler's return value and exits with the status that was
# pending when the handler was entered, so reporting here can neither mask nor
# downgrade the original failure.
#
#   proxy-config | kubeconfig | aws-config | ocm-login | cluster-id | exports |
#   mc-lookup-name | mc-lookup-id | mc-api-listening | mc-credentials |
#   mc-validate | test-args | test-execution | done
#
# "init" is only the initial value; the first stage is assigned before anything
# that can fail, so it is never reported.
SETUP_STAGE="init"

report_setup_failure(){
    local status=$?
    local stage="${SETUP_STAGE:-unknown}"
    # Once the test binary has been reached, its own output and JUnit report
    # describe the outcome; stay quiet so the suite result is not obscured.
    if [[ "${status}" -ne 0 && "${stage}" != "test-execution" && "${stage}" != "done" ]]; then
        # Never let a failure of the reporting itself replace the pending status.
        {
            log "SETUP FAILED: stage=${stage} exit=${status}"
            case "${stage}" in
                mc-lookup-id|mc-api-listening|mc-credentials)
                    log "SETUP FAILED: the e2e suite was not started and no JUnit report was produced; this stage discards its stderr on purpose, so the underlying error is not in this log"
                    ;;
                *)
                    log "SETUP FAILED: the e2e suite was not started and no JUnit report was produced"
                    ;;
            esac
        } || true
    fi
    return "${status}"
}
trap report_setup_failure EXIT

# For private clusters the API server is not reachable directly; a preceding
# step (rosa-cluster-credentials-backplane) writes proxy-conf.sh so oc / e2e.test
# traffic is routed to the backplane endpoint through the corp proxy. This is a
# no-op for public clusters, which do not create the file.
SETUP_STAGE="proxy-config"
if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  log "Private cluster detected, sourcing proxy configuration"
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# When a kubeconfig has been provisioned in SHARED_DIR (e.g. via backplane for
# private clusters), hand it to the test binary directly.
SETUP_STAGE="kubeconfig"
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  log "Using provisioned kubeconfig at ${KUBECONFIG}"
fi

# Configure AWS
SETUP_STAGE="aws-config"
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
else
  log "No AWS credentials found in cluster profile"
fi

# Log into OCM
SETUP_STAGE="ocm-login"
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
  export OCM_CLIENT_ID="${SSO_CLIENT_ID}"
  export OCM_CLIENT_SECRET="${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  export OCM_TOKEN="${ROSA_TOKEN}"
else
  log "No OCM credentials found in cluster profile"
  exit 1
fi

# Get cluster info from shared dir
SETUP_STAGE="cluster-id"
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Testing cluster: ${CLUSTER_ID}"

SETUP_STAGE="exports"
export OCM_ENV="${OCM_LOGIN_ENV}"
export CLUSTER_ID
export AWS_REGION="${REGION:-${LEASED_RESOURCE}}"

# Try to get management cluster access via OCM API
log "Attempting management cluster access..."
SETUP_STAGE="mc-lookup-name"
MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/hypershift 2>/dev/null | jq -r '.management_cluster // empty') || true
if [[ -n "${MC_NAME}" ]]; then
  log "Management cluster name: ${MC_NAME}"
  SETUP_STAGE="mc-lookup-id"
  MANAGEMENT_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name='${MC_NAME}'" --parameter size=1 2>/dev/null | jq -r '.items[0].id // empty')
  if [[ -n "${MANAGEMENT_CLUSTER_ID}" ]]; then
    SETUP_STAGE="mc-api-listening"
    MC_LISTENING=$(ocm get /api/clusters_mgmt/v1/clusters/"${MANAGEMENT_CLUSTER_ID}" 2>/dev/null | jq -r '.api.listening // empty')
    if [[ "${MC_LISTENING}" == "external" ]]; then
      log "Management cluster ${MANAGEMENT_CLUSTER_ID} API is external, fetching kubeconfig..."
      SETUP_STAGE="mc-credentials"
      MC_KUBECONFIG_FILE="${SHARED_DIR}/mc-kubeconfig"
      set +x
      ocm get /api/clusters_mgmt/v1/clusters/"${MANAGEMENT_CLUSTER_ID}"/credentials 2>/dev/null | jq -r '.kubeconfig' > "${MC_KUBECONFIG_FILE}"
      set -x 2>/dev/null || true
      SETUP_STAGE="mc-validate"
      if KUBECONFIG="${MC_KUBECONFIG_FILE}" oc whoami &>/dev/null; then
        export MC_KUBECONFIG="${MC_KUBECONFIG_FILE}"
        export MANAGEMENT_CLUSTER_ID
        log "Management cluster access established: ${MANAGEMENT_CLUSTER_ID}"
      else
        log "WARNING: MC kubeconfig fetched but failed validation (oc whoami failed), skipping MC access"
        rm -f "${MC_KUBECONFIG_FILE}"
      fi
    else
      log "Management cluster ${MANAGEMENT_CLUSTER_ID} API is ${MC_LISTENING:-unknown}, skipping MC access"
    fi
  else
    log "Could not resolve management cluster ID for ${MC_NAME}"
  fi
else
  log "No management cluster found for cluster ${CLUSTER_ID} (not HCP or hypershift info unavailable)"
fi

# Run tests
SETUP_STAGE="test-args"
GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e.xml" "--ginkgo.v")
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi

if [[ -n "${CLUSTER_TOPOLOGY:-}" ]]; then
  export CLUSTER_TOPOLOGY
fi

if [[ -n "${EXCLUDE_CLUSTER_OPERATORS:-}" ]]; then
  export EXCLUDE_CLUSTER_OPERATORS
fi

log "Running rosa-e2e tests: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
SETUP_STAGE="test-execution"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"

log "Tests complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e.xml"
SETUP_STAGE="done"
