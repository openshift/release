#!/usr/bin/env bash

# Never emit credential-bearing endpoint values through shell tracing.
set +x
set -o errexit
set -o nounset
set -o pipefail

cleanup_children() {
  local children
  children=$(jobs -p) || true
  if [[ -n "${children}" ]]; then
    kill ${children} && wait
  fi
}
trap 'cleanup_children; exit 1' TERM INT

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
VERSION_DEFAULT="${OPENSHIFT_VERSION:-}"
CHANNEL_GROUP_DEFAULT="${ARO_HCP_OPENSHIFT_CHANNEL_GROUP:-${OPENSHIFT_CHANNEL_GROUP:-nightly}}"
REPLICAS_DEFAULT="${REPLICAS:-0}"
PROVISION_SHARD_ID_DEFAULT="${ARO_HCP_PROVISION_SHARD_ID:-}"

# Send an Elasticsearch request without exposing credential-bearing diagnostics.
curl_es() {
  # Suppress curl diagnostics because the endpoint can contain basic-auth
  # credentials. Callers emit sanitized, generic failure messages instead.
  curl --silent --connect-timeout 15 --max-time 90 "$@"
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
  --arg version_default "${VERSION_DEFAULT}" \
  --arg channel_group_default "${CHANNEL_GROUP_DEFAULT}" \
  --arg replicas_default "${REPLICAS_DEFAULT}" \
  --arg provision_shard_id_default "${PROVISION_SHARD_ID_DEFAULT}" \
  '. as $doc |
   $doc.timers as $timers |
   def num:
     if . == null then null
     elif type == "number" then .
     elif type == "string" and test("^-?[0-9]+$") then tonumber
     else null
     end;
   ($timers.global_start | num) as $global_start_value |
   ($timers.global_end | num) as $global_end_value |
   ($timers.control_plane_install_seconds | num) as $control_plane_explicit |
   ($timers.control_plane_install_start | num) as $control_plane_start |
   ($timers.control_plane_ready | num) as $control_plane_ready |
   (if $control_plane_explicit != null then $control_plane_explicit
    elif $control_plane_start != null and $control_plane_ready != null then ($control_plane_ready - $control_plane_start)
    else null end) as $control_plane |
   (($timers.install // {}) | with_entries(.value |= ((. | num) // 0))) as $install_numeric |
   ({claim: 0, waiting: 0, validating: 0, pending: 0, installing: 0} + $install_numeric) as $install_defaults |
   ([$install_defaults | to_entries[] | select(.key | IN("claim", "waiting", "validating", "pending", "installing")) | .value] | add // 0) as $install_total |
   (if $install_total == 0 and (($control_plane // 0) > 0) then $install_defaults + {installing: $control_plane} else $install_defaults end) as $install |
   ($timers.install_ready | num) as $install_ready_explicit |
   (if $install_ready_explicit != null and $install_ready_explicit > 0 then $install_ready_explicit
    elif $control_plane != null then $control_plane
    else (($timers.cluster_ready | num) // 0) end) as $install_ready |
   ($timers.cluster_ready_seconds | num) as $guest_ready_explicit |
   ($timers.nodepool_install_seconds | num) as $nodepool |
   ($doc.nodepools // {}) as $nodepools |
   (($timers.nodepool_ready_seconds | num) // ([$nodepools[]? | .ready_seconds? | num | select(. != null)] | max // 0)) as $nodepool_ready |
   ($timers.total_install_time | num) as $total_explicit |
   (($total_explicit // (if $global_end_value != null and $global_end_value > ($global_start_value // 0) then $global_end_value - ($global_start_value // 0) else (($guest_ready_explicit // $control_plane) // 0) end))) as $total |
   ($global_start_value // 0) as $global_start |
   ($global_end_value // ($global_start + $total)) as $global_end |
   ($doc.cluster // {}) as $cluster |
   ($doc.version // {}) as $version |
   ($doc.nodes // {}) as $nodes |
   $doc + {
     name: ($doc.name // $cluster.name // ""),
     sts: ($doc.sts // false),
     hypershift: ($doc.hypershift // true),
     region: ($doc.region // $cluster.location // ""),
     version: {
       major_version: ($version.major_version // $version_default),
       raw_id: ($version.raw_id // $version_default),
       channel_group: ($version.channel_group // $channel_group_default)
     },
     # rosa-metadata maps tags as a text field, so do not send the ARO
     # cluster-config placeholder object ({}) to the shared index.
     tags: (if (($doc.tags // "") | type) == "string" then ($doc.tags // "") else "" end),
     multi_az: ($doc.multi_az // false),
     disable_scp_checks: ($doc.disable_scp_checks // false),
     disable_workload_monitoring: ($doc.disable_workload_monitoring // false),
     etcd_encryption: ($doc.etcd_encryption // false),
     enable_customer_managed_key: ($doc.enable_customer_managed_key // false),
     fips: ($doc.fips // false),
     private: ($doc.private // false),
     private_link: ($doc.private_link // false),
     default_ingress_private: ($doc.default_ingress_private // false),
     autoscaling: ($doc.autoscaling // {enabled: false}),
     nodes: {
       install_nodes: (($nodes.install_nodes // $replicas_default) | tostring),
       replicas: (($nodes.replicas // ($replicas_default | tonumber? // 0)) | tostring)
     },
     properties: (($doc.properties // {}) + {provision_shard_id: (($doc.properties.provision_shard_id // $provision_shard_id_default) | tostring)}),
     subnets: ($doc.subnets // {private_subnet_ids: "", public_subnet_ids: ""}),
     uuid: $uuid,
     timestamp: $timestamp,
     index_type: $index_type,
     timers: ($timers + {
       global_start: ($global_start | tostring),
       global_end: ($global_end | tostring),
       status: (if (($timers.status // "") == "Succeeded") then "ready" else ($timers.status // "ready") end),
       install: ($install | with_entries(.value |= tostring)),
       co_wait_time: (($timers.co_wait_time | num) // 0 | tostring),
       nodes_ready: (($timers.nodes_ready | num) // 0 | tostring),
       install_ready: ($install_ready | tostring),
       cluster_ready: ($install_ready | tostring),
       total_install_time: ($total | tostring),
       destroy: (($timers.destroy | num) // 0 | tostring),
       sts_destroy: (($timers.sts_destroy | num) // 0 | tostring),
       control_plane_install_time: $control_plane,
       nodepool_install_time: $nodepool,
       nodepool_ready_time: $nodepool_ready,
       cluster_ready_time: (($guest_ready_explicit // $total) | tonumber)
     })
   }' "${metadata_path}" > "${payload}"

http_status=$(curl_es -X POST "${ES_SERVER}/${ES_INDEX_VALUE}/_doc" \
  -H 'Content-Type: application/json' \
  --data-binary "@${payload}" \
  -o "${response}" \
  -w '%{http_code}' || true)
if [[ ! "${http_status}" =~ ^2[0-9][0-9]$ ]]; then
  error_reason=$(jq -r '.error.reason // .error.type // .message // empty' "${response}" 2>/dev/null || true)
  if [[ -n "${error_reason}" ]]; then
    echo "Elasticsearch indexing request failed (HTTP ${http_status}): ${error_reason}" >&2
  else
    echo "Elasticsearch indexing request failed (HTTP ${http_status})." >&2
  fi
  exit 1
fi

result=$(jq -r '.result // empty' "${response}")
if [[ "${result}" != "created" && "${result}" != "updated" && "${result}" != "indexed" ]]; then
  echo "Elasticsearch rejected the ARO HCP metadata document." >&2
  exit 1
fi
echo "Indexed ARO HCP installation timers (uuid=${UUID_VALUE}, result=${result})."
