#!/usr/bin/env bash

# Never emit credential-bearing endpoint values through shell tracing.
set +x
set -o errexit
set -o nounset
set -o pipefail

trap 'children=$(jobs -p); if [[ -n "${children}" ]]; then kill ${children} 2>/dev/null || true; wait ${children} 2>/dev/null || true; fi' TERM INT

if [[ "${INDEX_ENABLED}" != "true" ]]; then
  echo "ARO HCP metadata indexing is disabled (INDEX_ENABLED=${INDEX_ENABLED})."
  exit 0
fi

metadata_path="${SHARED_DIR}/${METADATA_FILE:-cluster-config}"
if [[ ! -s "${metadata_path}" ]] || ! jq empty "${metadata_path}" >/dev/null 2>&1; then
  echo "Missing or invalid ARO HCP metadata file: ${metadata_path}" >&2
  exit 1
fi

endpoint_file="${ES_SERVER_FILE:-/secret/host}"
if [[ ! -s "${endpoint_file}" ]]; then
  echo "Missing Elasticsearch endpoint credential: ${endpoint_file}" >&2
  exit 1
fi
ES_SERVER=$(tr -d '\r\n' < "${endpoint_file}")
ES_SERVER="${ES_SERVER%/}"
: "${ES_SERVER:?Elasticsearch endpoint is empty}"
ES_INDEX_VALUE="${ES_INDEX:-rosa-metadata}"

# Send an Elasticsearch request without exposing credential-bearing diagnostics.
curl_es() {
  # Suppress curl diagnostics because the endpoint can contain basic-auth
  # credentials. Callers emit sanitized, generic failure messages instead.
  curl --fail --silent --connect-timeout 15 --max-time 90 "$@"
}

if ! curl_es "${ES_SERVER}" | jq -e '.cluster_name != null' >/dev/null 2>&1; then
  echo "Unable to connect to the configured Elasticsearch endpoint." >&2
  exit 1
fi
if ! curl_es "${ES_SERVER}/_cat/indices?h=status,index&format=json" \
  | jq -e --arg index "${ES_INDEX_VALUE}" 'any(.[]?; .index == $index and .status == "open")' >/dev/null 2>&1; then
  echo "Elasticsearch index ${ES_INDEX_VALUE} is not open or does not exist." >&2
  exit 1
fi

UUID_VALUE="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload=$(mktemp)
response=$(mktemp)
# Remove temporary request files when indexing exits.
cleanup() {
  rm -f "${payload}" "${response}"
}
trap cleanup EXIT

jq \
  --arg uuid "${UUID_VALUE}" \
  --arg timestamp "${TIMESTAMP}" \
  --arg index_type "aro-hcp-install-timers" \
  '.timers as $timers |
   ($timers.control_plane_install_seconds // null) as $control_plane |
   ($timers.nodepool_install_seconds // null) as $nodepool |
   ($timers.nodepool_ready_seconds // .nodepools.workers.ready_seconds // null) as $nodepool_ready |
   ($timers.cluster_ready_seconds // $timers.total_install_time // null) as $cluster_ready |
   ($timers.install_ready // ([($timers.install // {}) | to_entries[] | select(.value | type == "number") | .value] | add // null)) as $install_ready |
   . + {
    uuid: $uuid,
    timestamp: $timestamp,
    index_type: $index_type,
    timers: ($timers + {
      install: ($timers.install // {}),
      install_ready: $install_ready,
      cluster_ready: $cluster_ready,
      total_install_time: ($timers.total_install_time // $cluster_ready),
      control_plane_install_time: $control_plane,
      nodepool_install_time: $nodepool,
      nodepool_ready_time: $nodepool_ready,
      cluster_ready_time: $cluster_ready
    })
  }' "${metadata_path}" > "${payload}"

if ! curl_es -X POST "${ES_SERVER}/${ES_INDEX_VALUE}/_doc" \
  -H 'Content-Type: application/json' \
  --data-binary "@${payload}" > "${response}"; then
  echo "Elasticsearch indexing request failed." >&2
  exit 1
fi

result=$(jq -r '.result // empty' "${response}")
if [[ "${result}" != "created" && "${result}" != "updated" && "${result}" != "indexed" ]]; then
  echo "Elasticsearch rejected the ARO HCP metadata document." >&2
  exit 1
fi
echo "Indexed ARO HCP installation timers (uuid=${UUID_VALUE}, result=${result})."
