#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Publishes the frozen provisioner-to-validator SHARED_DIR contract (ROSAENG-67580) for a cluster
# that was provisioned by the rosa CLI steps (rosa-cluster-provision). cluster-id and the admin
# kubeconfig are already produced by that flow (rosa-cluster-provision writes cluster-id,
# rosa-conf-idp-htpasswd writes kubeconfig); this step adds the remaining contract artifact,
# cluster-metadata.json, using the same schema as rosa-e2e-ocm-provision so the provisioner-agnostic
# validation refs cannot tell which head produced the cluster. This is the rosa-CLI head of the
# provision x validate matrix (ROSAENG-308 / ROSAENG-67583).

# The customer kubeconfig is token-bearing. Keep every file this step creates private at creation.
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

# cluster-id is produced by the rosa CLI provisioner (rosa-cluster-provision).
if [[ ! -s "${SHARED_DIR}/cluster-id" ]]; then
  log "ERROR: ${SHARED_DIR}/cluster-id is missing; rosa-cluster-provision must run before this step"
  exit 1
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Publishing SHARED_DIR contract for cluster ${CLUSTER_ID}"

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

# ---- Contract artifact: ${SHARED_DIR}/kubeconfig (customer plane) ----
# The rosa CLI flow writes the customer-plane admin kubeconfig via rosa-conf-idp-htpasswd (oc login).
# If it is absent, leave it unset: rosa-backplane-login provides bp-kubeconfig for the customer plane,
# and the customer-plane validation fails loudly if neither is present. We deliberately do not fetch
# the kubeconfig from the OCM credentials API as a fallback: for a private cluster that call still
# returns a kubeconfig, but one pointing at an internal API endpoint that is unreachable from CI, so
# writing it would mask the need for backplane and make the downstream steps unstable.
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  # Lock down the token-bearing file to match the OCM head (rosa-conf-idp-htpasswd does not chmod it).
  chmod 0600 "${SHARED_DIR}/kubeconfig"
  log "Using customer-plane kubeconfig from rosa-conf-idp-htpasswd"
else
  log "No customer-plane kubeconfig from rosa-conf-idp-htpasswd; backplane-login will provide bp-kubeconfig"
fi

# ---- Contract artifact: ${SHARED_DIR}/cluster-metadata.json (ROSAENG-67580) ----
# Same schema as rosa-e2e-ocm-provision so validation refs self-select assertions without per-job
# config and cannot tell the heads apart. schema_version lets the contract evolve; bump it when the
# shape changes.
# Fail rather than publish an incomplete contract: if the cluster lookup fails we would otherwise
# write empty name/region/version and let every downstream step run against bad metadata.
if ! cluster_json=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"); then
  log "ERROR: failed to fetch cluster ${CLUSTER_ID} from OCM; cannot publish the contract"
  exit 1
fi
resolved_region=$(jq -r '.region.id // empty' <<<"${cluster_json}")
resolved_version=$(jq -r '.version.raw_id // .openshift_version // empty' <<<"${cluster_json}")
resolved_channel=$(jq -r '.version.channel_group // empty' <<<"${cluster_json}")
resolved_name=$(jq -r '.name // empty' <<<"${cluster_json}")
if [[ -z "${resolved_name}" && -s "${SHARED_DIR}/cluster-name" ]]; then
  resolved_name=$(head -n 1 "${SHARED_DIR}/cluster-name")
fi
# The cluster name and region identify the cluster under test; refuse to publish a contract without
# them rather than emitting empty strings the validation refs would silently accept.
if [[ -z "${resolved_name}" || -z "${resolved_region:-${REGION}}" ]]; then
  log "ERROR: incomplete cluster metadata (name='${resolved_name}', region='${resolved_region:-${REGION}}'); cannot publish the contract"
  exit 1
fi
if [[ "${HOSTED_CP}" == "true" ]]; then topology="hcp"; else topology="classic"; fi

jq -n \
  --arg schema_version "1.0.0" \
  --arg provisioner "rosa-e2e-cli" \
  --arg cluster_id "${CLUSTER_ID}" \
  --arg cluster_name "${resolved_name}" \
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
