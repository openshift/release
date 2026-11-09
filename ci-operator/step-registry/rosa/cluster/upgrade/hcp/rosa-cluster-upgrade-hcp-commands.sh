#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"

cluster_id=$(cat "${SHARED_DIR}/cluster-id")

HOLD_TIME_BEFORE_UPGRADE=${HOLD_TIME_BEFORE_UPGRADE:-"0"}
CP_UPGRADE_TIMEOUT=${CP_UPGRADE_TIMEOUT:-"14400"}
CHANNEL_GROUP=${CHANNEL_GROUP:-stable}
VERSION_OFFSET_FROM_LATEST=${VERSION_OFFSET_FROM_LATEST:-}
AVAILABLE_UPGRADE=${AVAILABLE_UPGRADE:-no}
TARGET_SELECTION_ERROR=""
SELECTED_Y_STREAM=""
UPGRADE_START_EPOCH=""
UPGRADE_START_ISO=""
UPGRADE_FROM_VERSION=""

# Capture sanitized ClusterOperator/node health before upgrade for gap-analysis Check #13.
# Relies on Prow's ambient KUBECONFIG from SHARED_DIR/kubeconfig. Node hostnames and
# network fields are omitted from published artifacts. Restore proxy before every return
# so later rosa CLI calls are not stuck on the cluster proxy.
write_pre_upgrade_snapshot() {
  local kube="${SHARED_DIR}/kubeconfig"
  if declare -F set_proxy >/dev/null; then
    set_proxy
  fi
  if [[ ! -f "${kube}" ]]; then
    log "No kubeconfig in SHARED_DIR; skipping pre-upgrade ClusterOperator snapshot"
    if declare -F unset_proxy >/dev/null; then
      unset_proxy
    fi
    return 0
  fi
  if ! oc whoami --request-timeout=30s &>/dev/null; then
    log "WARNING: kubeconfig is not usable; skipping pre-upgrade snapshot"
    if declare -F unset_proxy >/dev/null; then
      unset_proxy
    fi
    return 0
  fi
  if ! mkdir -p "${ARTIFACT_DIR}"; then
    log "WARNING: cannot create ARTIFACT_DIR; skipping pre-upgrade snapshot"
    if declare -F unset_proxy >/dev/null; then
      unset_proxy
    fi
    return 0
  fi
  oc get co -o wide --request-timeout=60s > "${ARTIFACT_DIR}/pre-upgrade-clusteroperators.txt" 2>/dev/null || true
  oc get co -o json --request-timeout=60s 2>/dev/null | jq '{
    items: [.items[] | {
      name: .metadata.name,
      available: (([.status.conditions[]? | select(.type=="Available") | .status] | first) // ""),
      degraded: (([.status.conditions[]? | select(.type=="Degraded") | .status] | first) // ""),
      progressing: (([.status.conditions[]? | select(.type=="Progressing") | .status] | first) // ""),
      version: ((.status.versions[]? | select(.name=="operator") | .version) // "")
    }]
  }' > "${ARTIFACT_DIR}/pre-upgrade-clusteroperators.json" || echo '{"items":[]}' > "${ARTIFACT_DIR}/pre-upgrade-clusteroperators.json"
  oc get nodes -o json --request-timeout=60s 2>/dev/null | jq '{
    items: [.items[] | {
      ready: (([.status.conditions[]? | select(.type=="Ready") | .status] | first) // ""),
      schedulable: ((.spec.unschedulable // false) | not)
    }]
  }' > "${ARTIFACT_DIR}/pre-upgrade-nodes.json" || echo '{"items":[]}' > "${ARTIFACT_DIR}/pre-upgrade-nodes.json"
  local cluster_version=""
  cluster_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' --request-timeout=30s 2>/dev/null || true)"
  jq -n \
    --arg cluster_version "${cluster_version}" \
    --arg captured_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg phase "pre-upgrade" \
    '{cluster_version: $cluster_version, captured_at: $captured_at, phase: $phase}' \
    > "${ARTIFACT_DIR}/pre-upgrade-metadata.json" || true
  log "Wrote pre-upgrade ClusterOperator snapshot for gap-analysis Check #13"
  if declare -F unset_proxy >/dev/null; then
    unset_proxy
  fi
}

# Write upgrade-metrics.json with duration and the resolved target version. Best-effort;
# does not fail the step. Prefer available_version from get_cluster_upgrade_path.
write_upgrade_metrics() {
  if [[ -z "${UPGRADE_START_EPOCH}" ]]; then
    return 0
  fi
  local end_epoch end_iso duration
  end_epoch="$(date +%s)"
  end_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  duration=$((end_epoch - UPGRADE_START_EPOCH))
  mkdir -p "${ARTIFACT_DIR}" || return 0
  jq -n \
    --arg start "${UPGRADE_START_ISO}" \
    --arg end_time "${end_iso}" \
    --argjson start_epoch "${UPGRADE_START_EPOCH}" \
    --argjson end_epoch "${end_epoch}" \
    --argjson duration_seconds "${duration}" \
    --arg from_version "${UPGRADE_FROM_VERSION:-}" \
    --arg to_version "${available_version:-${UPGRADED_TO_VERSION:-}}" \
    '{
      start: $start,
      end: $end_time,
      start_epoch: $start_epoch,
      end_epoch: $end_epoch,
      duration_seconds: $duration_seconds,
      from_version: $from_version,
      to_version: $to_version
    }' > "${ARTIFACT_DIR}/upgrade-metrics.json" || true
  log "Wrote upgrade-metrics.json duration_seconds=${duration}"
}
trap 'write_upgrade_metrics || true' EXIT

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        log "setting the proxy"
        log "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        log "no proxy setting."
    fi
}

function unset_proxy () {
    if test -s "${SHARED_DIR}/unset-proxy.sh" ; then
        log "unset the proxy"
        log "source ${SHARED_DIR}/unset-proxy.sh"
        source "${SHARED_DIR}/unset-proxy.sh"
    else
        log "no proxy setting found."
    fi
}

# List the available HCP Y-streams (X.Y) for the configured channel group, version-sorted
# and de-duplicated. The query, the AVAILABLE_UPGRADE filtering and the ordering track
# rosa/cluster/provision so that an index into this list means what it means there. The
# match is close but not bit-exact: this step additionally drops null and non-X.Y ids,
# which provision keeps, and both sides depend on being given the same CHANNEL_GROUP. A
# divergence therefore shifts the indexes, which the install-position check in
# y_stream_at_offset detects and refuses rather than silently mis-selecting. Returns
# non-zero when the ROSA query fails, so callers can fail closed instead of guessing.
list_available_y_streams() {
  local raw jq_filter
  # Mirror the install-side filter: with AVAILABLE_UPGRADE=yes the provision step keeps
  # only versions that advertise an upgrade, which shortens the list and shifts every
  # index in it. Applying a different filter here would silently resolve the offset
  # against a different list than the one the cluster was installed from. Only the
  # offset path indexes the list, so the filter is confined to it: the discovery path
  # must keep seeing every stream, or a newest stream that advertises no upgrade of its
  # own would be dropped and discovery would report no newer stream at all.
  if [[ "${AVAILABLE_UPGRADE}" == "yes" && -n "${VERSION_OFFSET_FROM_LATEST}" ]]; then
    jq_filter='.[] | select(.available_upgrades != null) | .raw_id // empty'
  else
    jq_filter='.[].raw_id // empty'
  fi
  raw=$(rosa list versions --channel-group "${CHANNEL_GROUP}" --hosted-cp -o json) || return 1
  # `.raw_id // empty` drops entries whose raw_id is JSON null or absent: a bare
  # `.[].raw_id` renders both as the literal string "null", which would otherwise
  # survive into the candidate list and produce a bogus "<prefix>-null" channel. The
  # trailing filter keeps only well-formed X.Y streams; an all-malformed response
  # therefore yields an empty list and the caller fails closed.
  echo "${raw}" | jq -r "${jq_filter}" | cut -d '.' -f1,2 \
    | { grep -E '^[0-9]+\.[0-9]+$' || true; } | sort -Vu
}

# Print the first Y-stream in the version-ordered list that is strictly newer than the
# cluster's current version. Returns non-zero (printing nothing) when the list holds no
# newer stream, so the caller can fail closed rather than re-running the same version or
# attempting a downgrade.
next_y_stream_after() {
  local current_version="$1" y_stream_list="$2"
  local current_stream stream older
  current_stream=$(echo "${current_version}" | cut -d '.' -f1,2)
  if [[ ! "${current_stream}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  while IFS= read -r stream; do
    # Skip blanks and anything that is not a well-formed X.Y stream, so a malformed
    # discovery response can never be selected as an upgrade target.
    if [[ ! "${stream}" =~ ^[0-9]+\.[0-9]+$ || "${stream}" == "${current_stream}" ]]; then
      continue
    fi
    older=$(printf '%s\n%s\n' "${current_stream}" "${stream}" | sort -V | head -n1)
    if [[ "${older}" == "${current_stream}" ]]; then
      echo "${stream}"
      return 0
    fi
  done <<< "$(printf '%s\n' "${y_stream_list}" | sort -V)"
  return 1
}

# Resolve the upgrade target stream from the offset the cluster was installed at.
#
# VERSION_OFFSET_FROM_LATEST is a *position* in the list above, not arithmetic on the
# minor number: rosa/cluster/provision and rosa/sts/account-roles/create install at
# index (total - offset - 1). The matching upgrade target is one position newer --
# offset-1, i.e. index (total - offset) -- which is exactly what the y-minus-N jobs
# mean when they upgrade a y-minus-N cluster. Deriving the target as minor+1 instead
# ignores the catalog entirely and breaks outright at a major boundary (4.22 -> 5.0);
# deriving it from the cluster's current version alone cannot notice that the cluster is
# no longer at the offset the job asked for.
#
# Sets SELECTED_Y_STREAM and returns 0 on success. On failure sets
# TARGET_SELECTION_ERROR to the reason and returns non-zero, so the caller fails closed
# rather than upgrading to a stream nobody asked for. Globals rather than stdout: the
# caller needs the reason, and a command substitution would discard it with the
# subshell. Failure cases: a malformed offset;
# an offset of 0, where the cluster is already on the newest stream and no newer target
# exists; an offset larger than the catalog can satisfy; and catalog drift, where the
# install index no longer holds the version the cluster is actually running.
y_stream_at_offset() {
  local offset="$1" current_version="$2" y_stream_list="$3"
  local -a ordered_streams=()
  local stream current_stream total install_index target_index target oldest_first
  TARGET_SELECTION_ERROR=""
  SELECTED_Y_STREAM=""

  current_stream=$(echo "${current_version}" | cut -d '.' -f1,2)
  if [[ ! "${current_stream}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    TARGET_SELECTION_ERROR="cluster version '${current_version}' is not a well-formed version"
    return 1
  fi
  # Deliberately stricter than ^[0-9]+$: bash reads a zero-padded "08" as octal, and
  # the resulting arithmetic error would abort the caller's compound command before it
  # could exit, turning a malformed offset into a fail-open.
  if [[ ! "${offset}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    TARGET_SELECTION_ERROR="VERSION_OFFSET_FROM_LATEST='${offset}' is not a non-negative integer without leading zeros"
    return 1
  fi
  while IFS= read -r stream; do
    if [[ -n "${stream}" ]]; then
      ordered_streams+=("${stream}")
    fi
  done <<< "${y_stream_list}"
  total=${#ordered_streams[@]}

  install_index=$(( total - offset - 1 ))
  target_index=$(( total - offset ))
  if (( install_index < 0 )); then
    TARGET_SELECTION_ERROR="offset ${offset} needs at least $(( offset + 1 )) Y-streams, channel group ${CHANNEL_GROUP} offers ${total}: ${ordered_streams[*]}"
    return 1
  fi
  if (( target_index > total - 1 )); then
    TARGET_SELECTION_ERROR="offset ${offset} selects the newest available stream ${ordered_streams[${install_index}]}; there is no newer Y-stream to upgrade to"
    return 1
  fi
  if [[ "${ordered_streams[${install_index}]}" != "${current_stream}" ]]; then
    TARGET_SELECTION_ERROR="catalog drift: offset ${offset} now points at ${ordered_streams[${install_index}]} but the cluster is running ${current_stream}; available: ${ordered_streams[*]}"
    return 1
  fi

  target="${ordered_streams[${target_index}]}"
  oldest_first=$(printf '%s\n%s\n' "${current_stream}" "${target}" | sort -V | head -n1)
  if [[ "${target}" == "${current_stream}" || "${oldest_first}" != "${current_stream}" ]]; then
    TARGET_SELECTION_ERROR="selected target ${target} is not newer than ${current_stream}"
    return 1
  fi
  SELECTED_Y_STREAM="${target}"
}

# Record how the upgrade channel was chosen, including on the failure paths, so an early
# exit is still diagnosable from the job artifacts. Only version strings and the channel
# group are published: no cluster or account identifiers, no credentials and no raw
# command output. Never aborts the step.
write_target_selection_diagnostics() {
  local current_stream="$1" target="$2" channel="$3" streams="$4"
  if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    return 0
  fi
  mkdir -p "${ARTIFACT_DIR}" || return 0
  if ! {
    printf 'channel_group: %s\n' "${CHANNEL_GROUP}"
    printf 'available_upgrade_filter: %s\n' "${AVAILABLE_UPGRADE}"
    printf 'install_version_offset: %s\n' "${VERSION_OFFSET_FROM_LATEST:-<unset>}"
    printf 'current_y_stream: %s\n' "${current_stream}"
    printf 'selected_target: %s\n' "${target:-<none>}"
    printf 'selected_channel: %s\n' "${channel:-<none>}"
    printf 'available_y_streams: %s\n' "$(printf '%s' "${streams}" | tr '\n' ' ')"
  } > "${ARTIFACT_DIR}/upgrade-target-selection.txt"; then
    log "WARNING: failed to write upgrade-target-selection.txt"
  fi
}

function get_cluster_upgrade_path () {
  current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
  available_versions=$(rosa list upgrade -c $cluster_id -ojson)
  available_version=""
  if [[ "$available_versions" != *"There are no available upgrades"* ]]; then
    current_prefix=$(echo "$current_version" | awk -F. '{print $1"."$2}')
    if [[ -n $available_versions ]]; then
      clean_data=$(echo "$available_versions" | sed 's/[][",]//g')
      readarray -t versionsList <<< "$(echo "$clean_data" | sed '/^[[:space:]]*$/d' | awk '{$1=$1;print}')"
      readarray -t sorted_versions < <(printf "%s\n" "${versionsList[@]}" | sort -rV)
      log "Available upgrade versions: ${sorted_versions[*]}"

      if [[ "$Z_STREAM_UPGRADE" == "true" ]]; then
        for ver in "${sorted_versions[@]}"; do
          if [[ "$ver" =~ ^${current_prefix}\. ]]; then
            available_version=$ver
            log "Z Stream Upgrade version: ($available_version)"
            break
          fi
        done
      else
        target_prefix=${UPGRADED_TO_VERSION:-}
        if [[ -n "$target_prefix" ]]; then
          for ver in "${sorted_versions[@]}"; do
            if [[ "$ver" =~ ^${target_prefix}\. ]]; then
              available_version=$ver
              log "Y Stream Upgrade version: ($available_version)"
              break
            fi
          done
        else
          for ver in "${sorted_versions[@]}"; do
            if [[ ! "$ver" =~ ^${current_prefix}\. ]]; then
              available_version=$ver
              log "Y Stream Upgrade version: ($available_version)"
              break
            fi
          done
        fi
      fi
    fi
  fi
}


function upgrade_cluster_to () {
  available_version=$1
  start_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
  log "Upgrade the cluster $cluster_id to $available_version"
  echo "rosa upgrade cluster -y -m auto --version $available_version -c $cluster_id" 
  start_time=$(date +"%s")
  while true; do
    if (( $(date +"%s") - $start_time >= 1800 )); then
      log "error: Timed out while waiting for the previous upgrade schedule to be removed."
      exit 1
    fi

    rosa upgrade cluster -y -m auto --version $available_version -c $cluster_id  1>"/tmp/update_info.txt" 2>&1 || true
    upgrade_info=$(cat "/tmp/update_info.txt")
    if [[ "$upgrade_info" == *"There is already"* ]]; then
      log "Waiting for the previous upgrade schedule to be removed."
      sleep 120
    else
      log -e "$upgrade_info"
      if [[ "$upgrade_info" == *"ERR:"* ]] || [[ "$upgrade_info" == *"failed to schedule"* ]]; then
        log "error: Upgrade scheduling failed. Aborting instead of waiting."
        mkdir -p "${ARTIFACT_DIR}" || true
        echo "$upgrade_info" > "${ARTIFACT_DIR}/upgrade-schedule-error.txt"
        exit 1
      fi
      break
    fi
  done

  # Monitor cluster
  start_time=$(date +"%s")
  while true; do
    sleep 120
    log "Wait for the cluster upgrading finished ..."
    current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
    if [[ "$current_version" == "$available_version" ]]; then
      record_cluster "timers.ocp_upgrade" "${available_version}" $(( $(date +"%s") - "${start_time}" ))
      log "Upgrade the cluster $cluster_id from $start_version to the openshift version $available_version successfully after $(( $(date +"%s") - ${start_time} )) seconds"
      break
    fi

    if (( $(date +"%s") - $start_time >= $CP_UPGRADE_TIMEOUT )); then
      log "error: Timed out while waiting for the cluster upgrading to be ready"
      set_proxy
      oc get clusteroperators
      exit 1
    fi
  done

}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# hold on before upgrading cluster
start_time=$(date +"%s")
echo "$(date): Beginning to wait: ${HOLD_TIME_BEFORE_UPGRADE} seconds"
while true; do
  current_time=$(date +"%s")
  if (( "${current_time}" - "${start_time}" < "${HOLD_TIME_BEFORE_UPGRADE}" )); then
    sleep 60
    echo "Hold on before upgrading cluster: $(date)"
  else
    break
  fi
done

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

HOSTED_CP=$(rosa describe cluster -c $cluster_id -o json | jq -r '.hypershift.enabled')
if [[ "$HOSTED_CP" != "true" ]]; then
  log "error: This step is only for ROSA HCP clusters, but the cluster $cluster_id is not HCP."
  exit 1
fi

init_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
UPGRADE_FROM_VERSION="${init_version}"
write_pre_upgrade_snapshot
UPGRADE_START_EPOCH="$(date +%s)"
UPGRADE_START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

UPGRADE_CHANNEL=${UPGRADE_CHANNEL:-}
UPGRADE_CHANNEL_PREFIX=${UPGRADE_CHANNEL_PREFIX:-candidate}
# Auto-derive the upgrade channel when it is not explicitly set and this is not a
# Z-stream upgrade.
#
# When the job pins the installed version with VERSION_OFFSET_FROM_LATEST, the channel is
# the one for the stream at offset-1 in the same list the install side indexed, resolved
# by y_stream_at_offset: a y-minus-3 cluster gets the y-minus-2 channel, so source and
# target are both expressed as positions in one list rather than inferred from the
# cluster alone. While the catalog is unchanged that position is also the next stream
# after the current one; the value of resolving it by offset is that y_stream_at_offset
# first confirms the cluster really is at the offset the job configured, and refuses when
# it is not. Without an offset the job pinned no position, so we keep discovering the
# next supported stream after the cluster's current version. The channel only opens the
# hop: get_cluster_upgrade_path below remains the authority on which version is taken.
current_y_stream=$(echo "$init_version" | cut -d '.' -f1,2)
if [[ -z "${UPGRADE_CHANNEL}" && "${Z_STREAM_UPGRADE:-false}" != "true" ]]; then
  if ! y_stream_list=$(list_available_y_streams); then
    write_target_selection_diagnostics "${current_y_stream}" "" "" ""
    log "Error: could not list versions for channel group ${CHANNEL_GROUP}; refusing to guess an upgrade channel."
    exit 1
  fi
  if [[ -z "${y_stream_list}" ]]; then
    write_target_selection_diagnostics "${current_y_stream}" "" "" ""
    log "Error: no Y-streams available in channel group ${CHANNEL_GROUP}; refusing to guess an upgrade channel."
    exit 1
  fi
  if [[ -n "${VERSION_OFFSET_FROM_LATEST}" ]]; then
    if ! y_stream_at_offset "${VERSION_OFFSET_FROM_LATEST}" "${init_version}" "${y_stream_list}"; then
      write_target_selection_diagnostics "${current_y_stream}" "" "" "${y_stream_list}"
      log "Error: ${TARGET_SELECTION_ERROR}"
      exit 1
    fi
    next_y_stream="${SELECTED_Y_STREAM}"
    UPGRADE_CHANNEL="${UPGRADE_CHANNEL_PREFIX}-${next_y_stream}"
    log "Upgrade channel from install offset ${VERSION_OFFSET_FROM_LATEST}: ${UPGRADE_CHANNEL} (available Y-streams: $(echo "${y_stream_list}" | tr '\n' ' '))"
  else
    if ! next_y_stream=$(next_y_stream_after "${init_version}" "${y_stream_list}"); then
      write_target_selection_diagnostics "${current_y_stream}" "" "" "${y_stream_list}"
      log "Error: no Y-stream newer than ${init_version} in channel group ${CHANNEL_GROUP}; available: $(echo "${y_stream_list}" | tr '\n' ' ')"
      exit 1
    fi
    UPGRADE_CHANNEL="${UPGRADE_CHANNEL_PREFIX}-${next_y_stream}"
    log "Auto-derived upgrade channel: ${UPGRADE_CHANNEL} (available Y-streams: $(echo "${y_stream_list}" | tr '\n' ' '))"
  fi
fi
write_target_selection_diagnostics "${current_y_stream}" "${next_y_stream:-}" "${UPGRADE_CHANNEL}" "${y_stream_list:-}"
if [[ -n "${UPGRADE_CHANNEL}" ]]; then
  log "Changing cluster channel to ${UPGRADE_CHANNEL}"
  rosa edit cluster -c $cluster_id --channel "${UPGRADE_CHANNEL}"
  sleep 60
fi

upgraded_to_version=$init_version
get_cluster_upgrade_path

if [ -n "$available_version" ]; then
  upgrade_cluster_to $available_version
  upgraded_to_version=$available_version
  log "Upgrade control plane from $init_version to $upgraded_to_version"
else
  log "No available version for upgrade from $init_version"
fi

echo "$upgraded_to_version" > "${SHARED_DIR}/upgraded_to_version"
log "Control plane upgraded to $upgraded_to_version"
 
