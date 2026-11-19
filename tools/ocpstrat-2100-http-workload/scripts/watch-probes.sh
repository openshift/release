#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 <namespace> <new-output-directory>" >&2
  exit 2
fi
namespace=$1
output_dir=$2
selector='app.kubernetes.io/name=ocpstrat-2100-http-workload,app.kubernetes.io/component=probe'
if [[ -e "$output_dir" && ( ! -d "$output_dir" || -n "$(ls -A "$output_dir")" ) ]]; then
  echo "The probe output directory must be new or empty." >&2
  exit 2
fi
mkdir -p "$output_dir"
lifecycle="$output_dir/probe-lifecycle.jsonl"
: > "$lifecycle"

declare -A streams stream_pods stream_nodes recorded known_pods
event() {
  local kind=$1 pod=${2:-} uid=${3:-} node=${4:-} restarts=${5:-0}
  jq -cn --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$kind" --arg pod "$pod" --arg podUID "$uid" \
    --arg node "$node" --argjson restarts "$restarts" \
    '{timestamp:$timestamp,event:$event,pod:$pod,podUID:$podUID,node:$node,restarts:$restarts}' \
    >> "$lifecycle"
}
stop_streams() {
  trap - INT TERM EXIT
  for key in "${!streams[@]}"; do
    kill "${streams[$key]}" 2>/dev/null || true
    wait "${streams[$key]}" 2>/dev/null || true
  done
  event watch-stopped
}
trap 'stop_streams; exit 0' INT TERM
trap stop_streams EXIT

event watch-started
printf 'Writing probe samples to %s; press Ctrl-C to stop.\n' "$output_dir"
while :; do
  if ! pods=$(oc -n "$namespace" get pods -l "$selector" -o json 2>/dev/null); then
    event list-error
    sleep 2
    continue
  fi
  declare -A current_pods=()
  while IFS='|' read -r pod uid node phase restarts running; do
    [[ -n "$pod" ]] || continue
    current_pods["$uid"]=1
    state="$pod:$node:$phase:$restarts"
    if [[ "${known_pods[$uid]-}" != "$state" ]]; then
      event "pod-$phase" "$pod" "$uid" "$node" "$restarts"
      known_pods["$uid"]=$state
    fi
    if [[ "$running" != true ]]; then continue; fi
    key="$uid:$restarts"
    if [[ -n "${recorded[$key]-}" ]]; then continue; fi
    recorded["$key"]=1
    short_uid=${uid:0:8}
    log_file="$output_dir/probe-$pod-$short_uid-r$restarts.jsonl"
    oc -n "$namespace" logs -f "$pod" -c probe \
      > "$log_file" 2> "$log_file.stderr" &
    streams["$key"]=$!
    stream_pods["$key"]=$pod
    stream_nodes["$key"]=$node
    event stream-started "$pod" "$uid" "$node" "$restarts"
  done < <(jq -r '.items[] |
    [.metadata.name, .metadata.uid, .spec.nodeName // "", .status.phase // "Unknown",
     (.status.containerStatuses[0].restartCount // 0 | tostring),
     (.status.containerStatuses[0].state.running != null | tostring)] | join("|")' <<< "$pods")

  for uid in "${!known_pods[@]}"; do
    if [[ -z "${current_pods[$uid]-}" ]]; then
      event pod-gone "${known_pods[$uid]%%:*}" "$uid"
      unset "known_pods[$uid]"
    fi
  done
  for key in "${!streams[@]}"; do
    if ! kill -0 "${streams[$key]}" 2>/dev/null; then
      wait "${streams[$key]}" 2>/dev/null || true
      event stream-ended "${stream_pods[$key]}" "${key%%:*}" \
        "${stream_nodes[$key]}" "${key##*:}"
      unset "streams[$key]" "stream_pods[$key]" "stream_nodes[$key]"
    fi
  done
  sleep 2
done
