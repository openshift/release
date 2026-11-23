#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Private clusters ship proxy-conf.sh so oc / e2e.test reach the private API
# through the corp proxy. No-op for public clusters.
if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  log "Private cluster detected, sourcing proxy configuration"
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# The backplane hosted-cluster kubeconfig (bp-kubeconfig, written by
# rosa-backplane-login) is exported as its own BP_KUBECONFIG env var so the suite
# can initialise a backplane client from it directly. This is the only credential
# that reaches private-link clusters, whose API server is not routable from the
# build farm (ROSAENG-67580 contract).
if [[ -s "${SHARED_DIR}/bp-kubeconfig" ]]; then
  export BP_KUBECONFIG="${SHARED_DIR}/bp-kubeconfig"
  log "Backplane hosted-cluster kubeconfig available at BP_KUBECONFIG=${BP_KUBECONFIG}"
fi

# The management-cluster kubeconfig (mc-kubeconfig, also written by
# rosa-backplane-login) is exported as MC_KUBECONFIG so the suite can verify
# management-cluster state, e.g. the hypershift NodePool CR autoscaling bounds
# for the Feature:Autoscaling spec. Not all provisioner heads run
# rosa-backplane-login, so this is optional.
if [[ -s "${SHARED_DIR}/mc-kubeconfig" ]]; then
  export MC_KUBECONFIG="${SHARED_DIR}/mc-kubeconfig"
  log "Management cluster kubeconfig available at MC_KUBECONFIG=${MC_KUBECONFIG}"
fi

# Customer plane validates from the guest cluster kubeconfig. Prefer the
# provisioner-written kubeconfig (direct API), and fall back to BP_KUBECONFIG for
# private-link clusters until the suite consumes BP_KUBECONFIG on its own.
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  log "Using customer-plane kubeconfig at ${KUBECONFIG}"
elif [[ -n "${BP_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${BP_KUBECONFIG}"
  log "Direct kubeconfig absent; using backplane hosted-cluster kubeconfig at ${KUBECONFIG}"
else
  log "ERROR: neither ${SHARED_DIR}/kubeconfig nor ${SHARED_DIR}/bp-kubeconfig found;"
  log "       run the provisioner and rosa-backplane-login before this step"
  exit 1
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
  export AWS_REGION="${REGION:-${LEASED_RESOURCE}}"
fi

# Shared VPC inputs (ROSAENG-63353): when the head provisioned the cluster in
# a shared VPC (ENABLE_SHARED_VPC=yes), publish the cross-account private
# hosted zone and shared role references so the Feature:SharedVPC specs can
# validate them. The specs skip themselves when these are absent, so this
# block is a no-op for the rest of the matrix. Credential file contents are
# never echoed.
if [[ -s "${SHARED_DIR}/hosted_zone_id" && -s "${SHARED_DIR}/hosted_zone_role_arn" && -s "${SHARED_DIR}/rosa_dns_domain" ]]; then
  SHARED_VPC_HOSTED_ZONE_ID="$(head -n 1 "${SHARED_DIR}/hosted_zone_id")"
  SHARED_VPC_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")"
  SHARED_VPC_BASE_DOMAIN="$(head -n 1 "${SHARED_DIR}/rosa_dns_domain")"
  export SHARED_VPC_HOSTED_ZONE_ID SHARED_VPC_ROLE_ARN SHARED_VPC_BASE_DOMAIN
  if [[ -s "${SHARED_DIR}/account-roles-arns" ]]; then
    SHARED_VPC_INSTALLER_ROLE_ARN="$(grep "Installer-Role" "${SHARED_DIR}/account-roles-arns" | head -n 1 || true)"
    [[ -n "${SHARED_VPC_INSTALLER_ROLE_ARN}" ]] && export SHARED_VPC_INSTALLER_ROLE_ARN
  fi
  if [[ -f "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
    export SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
  else
    log "WARNING: shared VPC inputs present but ${CLUSTER_PROFILE_DIR}/.awscred_shared_account not found;"
    log "         cross-account specs will skip themselves"
  fi
  log "Shared VPC inputs exported (hosted zone: ${SHARED_VPC_HOSTED_ZONE_ID})"
fi

# OCM credentials for the suite's BeforeSuite (config.Load requires OCM_TOKEN or
# OCM_CLIENT_ID/OCM_CLIENT_SECRET to open the SDK connection; specs also query OCM
# directly). Read from the cluster profile, never echoed. Mirrors rosa-e2e-test.
read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
SUITE_OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  export OCM_CLIENT_ID="${SSO_CLIENT_ID}"
  export OCM_CLIENT_SECRET="${SSO_CLIENT_SECRET}"
elif [[ -n "${SUITE_OCM_TOKEN}" ]]; then
  export OCM_TOKEN="${SUITE_OCM_TOKEN}"
else
  log "ERROR: no OCM credentials found in cluster profile (sso-client-id/secret or ocm-token)"
  exit 1
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
export CLUSTER_ID OCM_ENV="${OCM_LOGIN_ENV}"

# Self-select feature assertions from the frozen contract metadata (ROSAENG-67580)
# instead of per-job config: export each feature flag as FEATURE_<NAME> and the
# topology so the suite enables/skips the right specs.
META="${SHARED_DIR}/cluster-metadata.json"
if [[ -s "${META}" ]]; then
  while IFS="=" read -r k v; do
    [[ -n "${k}" ]] && export "FEATURE_${k^^}=${v}"
  done < <(jq -r '.feature_flags // {} | to_entries[] | "\(.key)=\(.value)"' "${META}")
  if [[ -z "${CLUSTER_TOPOLOGY:-}" ]]; then
    CLUSTER_TOPOLOGY=$(jq -r '.topology // empty' "${META}")
    [[ -n "${CLUSTER_TOPOLOGY}" ]] && export CLUSTER_TOPOLOGY
  fi
  log "Loaded feature flags from cluster-metadata.json (topology=${CLUSTER_TOPOLOGY:-unset})"
else
  log "WARNING: ${META} not found; running without contract-driven feature selection"
fi

GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e-customer.xml" "--ginkgo.v")
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi
# A filter that selects no specs at all (e.g. the image predates the spec a
# dedicated workflow scopes to) must fail instead of silently passing.
# Skipped specs still count as selected, so this only fires on an empty match.
GINKGO_ARGS+=("--ginkgo.fail-on-empty")

log "Running customer-plane validation: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"
log "Customer-plane validation complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e-customer.xml"
