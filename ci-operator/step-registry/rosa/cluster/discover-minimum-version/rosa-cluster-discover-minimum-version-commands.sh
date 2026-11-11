#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# Logs timestamped messages to stderr
log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >&2
}

# Reads a file from the cluster profile directory if it exists
read_profile_file() {
  local file="$1"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

if [[ ! "${MIN_VERSION_SECTOR}" =~ ^[A-Za-z0-9_.:=-]+$ ]]; then
  log "ERROR: MIN_VERSION_SECTOR must contain only letters, numbers, dots, dashes, underscores, colons, equals, or hyphens"
  exit 1
fi

if [[ -n "${MIN_VERSION_Y_STREAM}" && ! "${MIN_VERSION_Y_STREAM}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  log "ERROR: MIN_VERSION_Y_STREAM must be empty or an X.Y version"
  exit 1
fi

if [[ "${HOSTED_CP}" != "true" ]]; then
  log "ERROR: minimum-version discovery currently supports ROSA HCP only"
  exit 1
fi

# Disable tracing to protect credential data from logs
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

sso_client_id="$(read_profile_file sso-client-id)"
sso_client_secret="$(read_profile_file sso-client-secret)"
rosa_token="$(read_profile_file ocm-token)"

if [[ -n "${sso_client_id}" && -n "${sso_client_secret}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id="${sso_client_id}" --client-secret="${sso_client_secret}"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id="${sso_client_id}" --client-secret="${sso_client_secret}"
elif [[ -n "${rosa_token}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with an offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token="${rosa_token}"
  rosa login --env "${OCM_LOGIN_ENV}" --token="${rosa_token}"
else
  log "ERROR: the cluster profile does not contain OCM credentials"
  exit 1
fi

# Restore tracing state
$WAS_TRACING && set -x

shards_file="$(mktemp)"
versions_file="$(mktemp)"
sorted_versions_file="$(mktemp)"
trap 'rm -f "${shards_file}" "${versions_file}" "${sorted_versions_file}"' EXIT TERM

page_size=100
page=1
while true; do
  response="$(ocm get /api/osd_fleet_mgmt/v1/service_clusters \
    --parameter search="sector is '${MIN_VERSION_SECTOR}'" \
    --parameter page="${page}" \
    --parameter size="${page_size}")"

  if ! jq -e '.items | type == "array"' >/dev/null <<<"${response}"; then
    log "ERROR: OSDFM returned an invalid service-cluster response"
    exit 1
  fi

  jq -r '.items[] | .provision_shard_reference.id // empty' <<<"${response}" >>"${shards_file}"
  item_count="$(jq '.items | length' <<<"${response}")"
  if (( item_count < page_size )); then
    break
  fi
  ((page += 1))
done

sort -u -o "${shards_file}" "${shards_file}"
shard_count="$(wc -l <"${shards_file}" | tr -d '[:space:]')"
if (( shard_count == 0 )); then
  log "ERROR: no provision shards were found in sector ${MIN_VERSION_SECTOR}"
  exit 1
fi
log "Found ${shard_count} provision shards in sector ${MIN_VERSION_SECTOR}"

while IFS= read -r shard_id; do
  if [[ ! "${shard_id}" =~ ^[A-Za-z0-9-]+$ ]]; then
    log "ERROR: OSDFM returned an invalid provision shard identifier"
    exit 1
  fi

  page=1
  while true; do
    response="$(ocm get /api/clusters_mgmt/v1/clusters \
      --parameter search="provision_shard_id = '${shard_id}' and status.state is 'ready'" \
      --parameter page="${page}" \
      --parameter size="${page_size}")"

    if ! jq -e '.items | type == "array"' >/dev/null <<<"${response}"; then
      log "ERROR: clusters_mgmt returned an invalid cluster response"
      exit 1
    fi

    jq -r --arg y_stream "${MIN_VERSION_Y_STREAM}" '
      .items[]
      | select((.hypershift.enabled // false) == true)
      | select((.cloud_provider.id // "") == "aws")
      | (.openshift_version // empty)
      | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | select($y_stream == "" or startswith($y_stream + "."))
    ' <<<"${response}" >>"${versions_file}"

    item_count="$(jq '.items | length' <<<"${response}")"
    if (( item_count < page_size )); then
      break
    fi
    ((page += 1))
  done
done <"${shards_file}"

sort -Vu -o "${sorted_versions_file}" "${versions_file}"
if [[ ! -s "${sorted_versions_file}" ]]; then
  if [[ -n "${MIN_VERSION_Y_STREAM}" ]]; then
    log "ERROR: no ready ROSA HCP clusters on ${MIN_VERSION_Y_STREAM}.Z were found in sector ${MIN_VERSION_SECTOR}"
  else
    log "ERROR: no ready ROSA HCP cluster versions were found in sector ${MIN_VERSION_SECTOR}"
  fi
  exit 1
fi

available_versions="$(rosa list versions --channel-group "${CHANNEL_GROUP}" --hosted-cp -o json | jq -r '.[].raw_id')"
minimum_version=""
while IFS= read -r fleet_version; do
  if grep -Fxq -- "${fleet_version}" <<<"${available_versions}"; then
    minimum_version="${fleet_version}"
    break
  fi
done <"${sorted_versions_file}"

if [[ -z "${minimum_version}" ]]; then
  log "ERROR: no fleet version is available for new HCP installations in channel group ${CHANNEL_GROUP}"
  exit 1
fi

printf '%s\n' "${minimum_version}" >"${SHARED_DIR}/minimum-openshift-version"
printf '%s\n' "${minimum_version}" >"${ARTIFACT_DIR}/minimum-openshift-version.txt"
jq -n \
  --arg environment "${OCM_LOGIN_ENV}" \
  --arg sector "${MIN_VERSION_SECTOR}" \
  --arg y_stream "${MIN_VERSION_Y_STREAM}" \
  --arg version "${minimum_version}" \
  '{environment: $environment, sector: $sector, requested_y_stream: $y_stream, minimum_version: $version}' \
  >"${ARTIFACT_DIR}/minimum-version-discovery.json"

log "Selected minimum installable fleet version ${minimum_version}"
