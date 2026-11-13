#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Private clusters ship proxy-conf.sh (written by rosa-cluster-credentials-backplane)
# so e2e.test reaches the backplane-routed MC/SC APIs through the corp proxy.
# No-op for public clusters.
if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  log "Private cluster detected, sourcing proxy configuration"
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Platform plane validates from the management cluster kubeconfig produced by
# rosa-backplane-login. Without it there is nothing to validate here.
MC_KUBECONFIG_FILE="${SHARED_DIR}/mc-kubeconfig"
if [[ ! -s "${MC_KUBECONFIG_FILE}" ]]; then
  log "ERROR: ${MC_KUBECONFIG_FILE} not found; run rosa-backplane-login before this step"
  exit 1
fi
export KUBECONFIG="${MC_KUBECONFIG_FILE}"
export MC_KUBECONFIG="${MC_KUBECONFIG_FILE}"
log "Using management-cluster kubeconfig at ${MC_KUBECONFIG_FILE}"

if [[ -s "${SHARED_DIR}/sc-kubeconfig" ]]; then
  export SC_KUBECONFIG="${SHARED_DIR}/sc-kubeconfig"
  log "Service-cluster kubeconfig available at ${SC_KUBECONFIG}"
else
  log "No sc-kubeconfig present; service-cluster specs will be skipped"
fi
if [[ -s "${SHARED_DIR}/mc-cluster-id" ]]; then
  MANAGEMENT_CLUSTER_ID=$(cat "${SHARED_DIR}/mc-cluster-id")
  export MANAGEMENT_CLUSTER_ID
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
export CLUSTER_ID OCM_ENV="${OCM_LOGIN_ENV}"

# AWS credentials for specs that validate cloud resources directly (e.g. the
# KMS key health spec queries the KMS API). Mirrors rosa-e2e-validate-customer.
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
  export AWS_REGION="${REGION:-${LEASED_RESOURCE}}"
fi

# Shared VPC inputs (ROSAENG-63353): publish the cross-account private hosted
# zone and shared role references for the Feature:SharedVPC management-plane
# specs (shared role trust validation). Specs skip themselves when absent, so
# this block is a no-op for the rest of the matrix. Credential file contents
# are never echoed. Mirrors rosa-e2e-validate-customer.
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
    # Same-account shared VPC mode: the shared resources live in the cluster
    # account, so the specs query them with the cluster credentials.
    export SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    log "No .awscred_shared_account in the cluster profile: running the shared VPC specs with the cluster account credentials (same-account mode)"
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

# Self-select feature assertions from the frozen contract metadata (ROSAENG-67580).
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

GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e-platform.xml" "--ginkgo.v")
LABEL_FILTER="${PLATFORM_LABEL_FILTER:-${LABEL_FILTER:-}}"
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi

log "Running platform-plane validation: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"
log "Platform-plane validation complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e-platform.xml"
