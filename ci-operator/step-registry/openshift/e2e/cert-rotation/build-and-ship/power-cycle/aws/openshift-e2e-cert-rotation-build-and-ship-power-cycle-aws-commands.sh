#!/bin/bash
# jq filters use $vars inside single quotes on purpose.
# shellcheck disable=SC2016
# Build-and-ship test, step 2 of 3 (AWS): stop every cluster instance, then start them again.
set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
readonly STATE="${SHARED_DIR}/build-and-ship-state.json"
[[ -f ${STATE} ]] || { echo "missing ${STATE}: run openshift-e2e-cert-rotation-build-and-ship-prep first" >&2; exit 1; }

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
die() {
  log "ERROR: $*"
  exit 1
}
now() { date -u +%s; }
dur() {
  local n=${1%[smhd]}
  case ${1: -1} in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) echo "$1" ;; esac
}
state_set() {
  local f=$1
  shift
  jq -c "$@" "$f" "${STATE}" >"${STATE}.tmp"
  mv "${STATE}.tmp" "${STATE}"
}

infra_id=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
AWS_DEFAULT_REGION=$(jq -r .aws.region "${SHARED_DIR}/metadata.json")
export AWS_DEFAULT_REGION
[[ -n $infra_id && $infra_id != null && $AWS_DEFAULT_REGION != null ]] || die "cannot read infraID and region from metadata.json"

ids=$(aws ec2 describe-instances --output json \
  --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].InstanceId' | jq -r 'join(" ")')
count=$(wc -w <<<"$ids")
want=$(jq '.nodes | length' "${STATE}")
((count == want)) || die "found ${count} running cluster instances (${ids}) but the cluster has ${want} nodes"

states() { # -> sorted unique instance states
  # shellcheck disable=SC2086
  aws ec2 describe-instances --output json --instance-ids $ids --query 'Reservations[].Instances[].State.Name' | jq -r 'unique | join(",")'
}
wait_state() { # state timeout-seconds
  local deadline=$(($(now) + $2)) s
  while (($(now) < deadline)); do
    s=$(states) || s=""
    log "instances: ${s:-?}"
    [[ $s == "$1" ]] && return 0
    sleep 15
  done
  return 1
}

log "stopping ${count} instances: ${ids}"
# shellcheck disable=SC2086
aws ec2 stop-instances --instance-ids $ids >/dev/null
state_set '.stop_requested_at = $t' --argjson t "$(now)"
if ! wait_state stopped "$(dur "${STOP_TIMEOUT}")"; then
  log "instances did not stop within ${STOP_TIMEOUT}; forcing"
  # shellcheck disable=SC2086
  aws ec2 stop-instances --force --instance-ids $ids >/dev/null
  wait_state stopped 600 || die "instances did not stop even when forced"
fi
state_set '.stopped_at = $t' --argjson t "$(now)"

log "starting instances"
# shellcheck disable=SC2086
aws ec2 start-instances --instance-ids $ids >/dev/null
wait_state running "$(dur "${START_TIMEOUT}")" || die "instances not running within ${START_TIMEOUT}"
state_set '.running_at = $t' --argjson t "$(now)"
now >"${SHARED_DIR}/build-and-ship-running-at"
log "all instances running again"
