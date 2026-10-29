#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Publishes the frozen provisioner-to-validator SHARED_DIR contract (ROSAENG-67580) for a cluster
# provisioned by the terraform-provider-rhcs day1 flow (rhcs-e2e-setup). This is the Terraform head
# of the provision x validate matrix (ROSAENG-308 / ROSAENG-67583), a sibling of
# rosa-e2e-rosa-cli-publish-contract and rosa-e2e-ocm-provision.
#
# rhcs-e2e-setup runs the provider's ginkgo "day1-prepare" suite with RHCS_OUTPUT=${SHARED_DIR}, so
# the suite's profile handler leaves ${SHARED_DIR}/cluster-name behind. It does not record the
# cluster id anywhere (day2 re-derives it from terraform state), and because every HCP profile in
# tests/ci/profiles currently sets admin_enabled: false it produces no guest kubeconfig either.
# This step therefore resolves the id from OCM by name and emits the contract artifacts the
# Terraform flow does not produce, using the same schema as the OCM and rosa-CLI heads so the
# provisioner-agnostic validation refs cannot tell which head produced the cluster.

# Anything written here may be token-bearing. Keep it private at creation.
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

# ---- Cluster name: the only identifier the Terraform day1 flow persists ----
# profilehandler.CreateRHCSClusterByProfile writes it to ${RHCS_OUTPUT}/cluster-name, and
# rhcs-e2e-setup sets RHCS_OUTPUT=${SHARED_DIR}.
if [[ ! -s "${SHARED_DIR}/cluster-name" ]]; then
  log "ERROR: ${SHARED_DIR}/cluster-name is missing; rhcs-e2e-setup must run before this step"
  exit 1
fi
CLUSTER_NAME=$(head -n 1 "${SHARED_DIR}/cluster-name" | tr -d '[:space:]')
if [[ -z "${CLUSTER_NAME}" ]]; then
  log "ERROR: ${SHARED_DIR}/cluster-name is empty"
  exit 1
fi
log "Publishing SHARED_DIR contract for Terraform-provisioned cluster '${CLUSTER_NAME}'"

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

# ---- Contract artifact: ${SHARED_DIR}/cluster-id ----
# Fetch with size=2 so an ambiguous name is detected rather than silently resolving to whichever
# cluster OCM happens to return first; publishing a contract for the wrong cluster would send the
# whole validation tail at someone else's cluster.
if ! clusters_json=$(ocm get /api/clusters_mgmt/v1/clusters \
                       --parameter search="name='${CLUSTER_NAME}'" --parameter size=2); then
  log "ERROR: failed to query OCM for cluster '${CLUSTER_NAME}'; cannot publish the contract"
  exit 1
fi
matched=$(jq -r '.items | length' <<<"${clusters_json}")
if (( matched == 0 )); then
  log "ERROR: no cluster named '${CLUSTER_NAME}' found in OCM (${OCM_LOGIN_ENV})"
  exit 1
elif (( matched > 1 )); then
  log "ERROR: cluster name '${CLUSTER_NAME}' is ambiguous in OCM (${OCM_LOGIN_ENV}); refusing to guess"
  exit 1
fi
cluster_json=$(jq -c '.items[0]' <<<"${clusters_json}")
CLUSTER_ID=$(jq -r '.id // empty' <<<"${cluster_json}")
if [[ -z "${CLUSTER_ID}" ]]; then
  log "ERROR: OCM returned cluster '${CLUSTER_NAME}' without an id; cannot publish the contract"
  exit 1
fi
echo "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
log "Resolved cluster '${CLUSTER_NAME}' to id ${CLUSTER_ID}"

# ---- Contract artifact: ${SHARED_DIR}/kubeconfig (customer plane) ----
# The provider's day2 suites write per-user kubeconfigs into ${RHCS_OUTPUT}/kubeconfig, i.e. a
# *directory* at the contract's kubeconfig path. day1-prepare does not create it, but move it aside
# if it ever appears: the validation refs treat ${SHARED_DIR}/kubeconfig as a file, and a non-empty
# directory there would be handed straight to KUBECONFIG.
if [[ -d "${SHARED_DIR}/kubeconfig" ]]; then
  log "WARNING: ${SHARED_DIR}/kubeconfig is a directory of per-user kubeconfigs; moving it to ${SHARED_DIR}/rhcs-kubeconfigs"
  rm -rf "${SHARED_DIR}/rhcs-kubeconfigs"
  mv "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/rhcs-kubeconfigs"
fi
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  chmod 0600 "${SHARED_DIR}/kubeconfig"
  log "Customer-plane kubeconfig is present"
else
  # Not an error: every HCP profile sets admin_enabled: false, so the Terraform day1 flow has no
  # cluster-admin credentials to build a kubeconfig from. rosa-e2e-validate-customer falls back to
  # bp-kubeconfig, so rosa-backplane-login must run between this chain and the validation tail.
  log "No customer-plane kubeconfig from the Terraform day1 flow; rosa-backplane-login must supply bp-kubeconfig"
fi

# ---- Contract artifact: ${SHARED_DIR}/cluster-metadata.json (ROSAENG-67580) ----
# Unlike the OCM and rosa-CLI heads, the Terraform flow is driven by a profile name (CLUSTER_PROFILE)
# rather than the per-feature env vars those heads use, so there is nothing to copy the feature flags
# from. Derive them from the OCM representation of the cluster instead: that is the same cluster the
# validation tail asserts against, and it keeps the flags honest about what Terraform actually built.
resolved_region=$(jq -r '.region.id // empty' <<<"${cluster_json}")
resolved_version=$(jq -r '.version.raw_id // .openshift_version // empty' <<<"${cluster_json}")
resolved_channel=$(jq -r '.version.channel_group // empty' <<<"${cluster_json}")
resolved_name=$(jq -r '.name // empty' <<<"${cluster_json}")
resolved_name="${resolved_name:-${CLUSTER_NAME}}"
# The cluster name and region identify the cluster under test; refuse to publish a contract without
# them rather than emitting empty strings the validation refs would silently accept.
if [[ -z "${resolved_name}" || -z "${resolved_region:-${REGION}}" ]]; then
  log "ERROR: incomplete cluster metadata (name='${resolved_name}', region='${resolved_region:-${REGION}}'); cannot publish the contract"
  exit 1
fi

# An explicit OCM value for hypershift.enabled always wins over the HOSTED_CP default
# (CodeRabbit review): an OCM "false" must publish classic even when HOSTED_CP=true.
# ${hypershift_enabled:-${HOSTED_CP}} falls back to HOSTED_CP only when OCM omits the
# field (hypershift_enabled is empty then). A plain "${HOSTED_CP} == true ||
# ${hypershift_enabled} == true" OR would reintroduce the bug: the HOSTED_CP default
# is true, so it would publish hcp for a classic cluster OCM reports as such.
# NB: jq's // operator treats false as falsy, so null has to be tested for explicitly
# to tell an explicit OCM "false" apart from an absent field.
hypershift_enabled=$(jq -r 'if .hypershift.enabled == null then "" else (.hypershift.enabled | tostring) end' <<<"${cluster_json}")
if [[ "${hypershift_enabled:-${HOSTED_CP}}" == "true" ]]; then
  topology="hcp"
else
  topology="classic"
fi

# ZERO_EGRESS stays an env knob: OCM has no stable top-level field for it, so the job declares it and
# we OR it with the property the service sets when it does.
feature_flags=$(jq -c --argjson zero_egress_env "$(bool "${ZERO_EGRESS}")" '{
    privatelink: (.aws.private_link // false),
    private: ((.api.listening // "external") == "internal"),
    kms: (((.aws.kms_key_arn // "") | length) > 0),
    etcd_encryption: (.etcd_encryption // false),
    fips: (.fips // false),
    sts: ((.aws.sts.enabled // false) or (((.aws.sts.role_arn // "") | length) > 0)),
    byovpc: (((.aws.subnet_ids // []) | length) > 0),
    sharedvpc: (((.aws.private_hosted_zone_id // "") | length) > 0),
    zero_egress: (((.properties.zero_egress // "false") == "true") or $zero_egress_env),
    multi_az: (.multi_az // false)
  }' <<<"${cluster_json}")

jq -n \
  --arg schema_version "1.0.0" \
  --arg provisioner "rosa-e2e-terraform-rhcs" \
  --arg cluster_id "${CLUSTER_ID}" \
  --arg cluster_name "${resolved_name}" \
  --arg topology "${topology}" \
  --arg region "${resolved_region:-${REGION}}" \
  --arg channel_group "${resolved_channel:-${CHANNEL_GROUP}}" \
  --arg openshift_version "${resolved_version:-${OPENSHIFT_VERSION}}" \
  --argjson feature_flags "${feature_flags}" \
  '{
    schema_version: $schema_version,
    provisioner: $provisioner,
    cluster_id: $cluster_id,
    cluster_name: $cluster_name,
    topology: $topology,
    region: $region,
    channel_group: $channel_group,
    openshift_version: $openshift_version,
    feature_flags: $feature_flags
  }' > "${SHARED_DIR}/cluster-metadata.json"

log "Wrote cluster-metadata.json contract:"
cat "${SHARED_DIR}/cluster-metadata.json" >&2
