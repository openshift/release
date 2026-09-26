#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# The customer kubeconfig is token-bearing. Make every file this step creates
# private at creation time so a redirection never leaves a secret readable by
# other users before an explicit chmod runs.
umask 0077

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Normalise a truthy env value to a JSON boolean.
bool() { [[ "${1,,}" =~ ^(true|yes|1)$ ]] && echo true || echo false; }

REGION="${REGION:-${LEASED_RESOURCE}}"
CLUSTER_NAME="${CLUSTER_NAME:-rosa-e2e-${RANDOM}}"

# ---- OCM login (SSO client credentials preferred, offline token fallback) ----
# Do not trace credential reads / ocm login.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  $WAS_TRACING && set -x
  log "ERROR: no OCM credentials found in cluster profile (sso-client-id/secret or ocm-token)"
  exit 1
fi
$WAS_TRACING && set -x

# AWS context for the provisioner (STS role assumption still needs the account).
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
  export AWS_REGION="${REGION}"
fi

# ---- Provision via the rosa-e2e OCM Go SDK provisioner ----
# The OCM-SDK provisioning logic is owned by the rosa-e2e repo and shipped in the
# `rosa-e2e` image. This ref is the CI wiring that turns that provisioning into
# the frozen SHARED_DIR contract (ROSAENG-67580). PROVISION_ENTRYPOINT must create
# the cluster and write its OCM id to ${SHARED_DIR}/cluster-id.
export OCM_ENV="${OCM_LOGIN_ENV}"
export CLUSTER_NAME REGION HOSTED_CP STS CHANNEL_GROUP OPENSHIFT_VERSION REPLICAS \
  COMPUTE_MACHINE_TYPE MULTI_AZ ENABLE_BYOVPC PRIVATE PRIVATE_LINK ETCD_ENCRYPTION \
  STORAGE_ENCRYPTION FIPS ENABLE_SHARED_VPC ZERO_EGRESS

if [[ -z "${PROVISION_ENTRYPOINT:-}" ]]; then
  log "ERROR: PROVISION_ENTRYPOINT is unset. Set it to the rosa-e2e OCM-SDK provisioner"
  log "       command (from the rosa-e2e image) that creates the cluster and writes"
  log "       its OCM id to \${SHARED_DIR}/cluster-id."
  exit 1
fi

log "Provisioning ROSA cluster '${CLUSTER_NAME}' (${REGION}) via OCM SDK: ${PROVISION_ENTRYPOINT}"
# shellcheck disable=SC2086
${PROVISION_ENTRYPOINT}

# The provisioner is expected to write cluster-id itself; fall back to resolving it
# by name from OCM if it did not.
if [[ ! -s "${SHARED_DIR}/cluster-id" ]]; then
  CID=$(ocm get /api/clusters_mgmt/v1/clusters \
          --parameter search="name='${CLUSTER_NAME}'" --parameter size=1 \
        | jq -r '.items[0].id // empty')
  if [[ -z "${CID}" ]]; then
    log "ERROR: provisioner produced no cluster-id and none found by name '${CLUSTER_NAME}'"
    exit 1
  fi
  echo -n "${CID}" > "${SHARED_DIR}/cluster-id"
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Provisioned cluster id: ${CLUSTER_ID}"

# ---- Contract artifact: ${SHARED_DIR}/kubeconfig (customer plane) ----
# The provisioner owns the guest kubeconfig: PROVISION_ENTRYPOINT is expected to
# write it. As a fallback we fetch it from OCM here, which succeeds only for
# public clusters that are already reachable. A miss is non-fatal (the entrypoint
# may have written it, or a private cluster is reached later via proxy-conf.sh);
# the customer-plane validation step fails loudly if the kubeconfig is still absent.
if [[ ! -s "${SHARED_DIR}/kubeconfig" ]]; then
  if ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" \
       | jq -re '.kubeconfig' > "${SHARED_DIR}/kubeconfig" 2>/dev/null; then
    chmod 0600 "${SHARED_DIR}/kubeconfig"
    log "Wrote customer-plane kubeconfig to \${SHARED_DIR}/kubeconfig"
  else
    rm -f "${SHARED_DIR}/kubeconfig"
    log "Guest kubeconfig not available from OCM (private cluster?); backplane-login will provide it"
  fi
fi

# ---- Contract artifact: ${SHARED_DIR}/cluster-metadata.json (ROSAENG-67580) ----
# Feature flags are derived from the provisioning inputs so validation refs can
# self-select assertions without per-job config. schema_version lets the contract
# evolve; bump it when the shape changes.
cluster_json=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" 2>/dev/null || echo '{}')
resolved_region=$(jq -r '.region.id // empty' <<<"${cluster_json}")
resolved_version=$(jq -r '.version.raw_id // .openshift_version // empty' <<<"${cluster_json}")
resolved_channel=$(jq -r '.version.channel_group // empty' <<<"${cluster_json}")
if [[ "${HOSTED_CP}" == "true" ]]; then topology="hcp"; else topology="classic"; fi

jq -n \
  --arg schema_version "1.0.0" \
  --arg provisioner "rosa-e2e-ocm" \
  --arg cluster_id "${CLUSTER_ID}" \
  --arg cluster_name "${CLUSTER_NAME}" \
  --arg topology "${topology}" \
  --arg region "${resolved_region:-${REGION}}" \
  --arg channel_group "${resolved_channel:-${CHANNEL_GROUP}}" \
  --arg openshift_version "${resolved_version:-${OPENSHIFT_VERSION}}" \
  --argjson privatelink "$(bool "${PRIVATE_LINK}")" \
  --argjson private "$(bool "${PRIVATE}")" \
  --argjson kms "$(bool "${STORAGE_ENCRYPTION}")" \
  --argjson etcd_encryption "$(bool "${ETCD_ENCRYPTION}")" \
  --argjson fips "$(bool "${FIPS}")" \
  --argjson sts "$(bool "${STS}")" \
  --argjson byovpc "$(bool "${ENABLE_BYOVPC}")" \
  --argjson sharedvpc "$(bool "${ENABLE_SHARED_VPC}")" \
  --argjson zero_egress "$(bool "${ZERO_EGRESS}")" \
  --argjson multi_az "$(bool "${MULTI_AZ}")" \
  '{
    schema_version: $schema_version,
    provisioner: $provisioner,
    cluster_id: $cluster_id,
    cluster_name: $cluster_name,
    topology: $topology,
    region: $region,
    channel_group: $channel_group,
    openshift_version: $openshift_version,
    feature_flags: {
      privatelink: $privatelink,
      private: $private,
      kms: $kms,
      etcd_encryption: $etcd_encryption,
      fips: $fips,
      sts: $sts,
      byovpc: $byovpc,
      sharedvpc: $sharedvpc,
      zero_egress: $zero_egress,
      multi_az: $multi_az
    }
  }' > "${SHARED_DIR}/cluster-metadata.json"

log "Wrote cluster-metadata.json contract:"
cat "${SHARED_DIR}/cluster-metadata.json" >&2
