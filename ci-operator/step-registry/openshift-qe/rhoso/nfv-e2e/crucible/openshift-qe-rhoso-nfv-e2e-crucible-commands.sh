#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${SCENARIO:?SCENARIO must be set}"
: "${TIMEOUT_CRUCIBLE:?TIMEOUT_CRUCIBLE must be set}"
: "${EDPM_HOST:?EDPM_HOST must be set}"
: "${FRAME_SIZES:?FRAME_SIZES must be set}"

[[ "${TIMEOUT_CRUCIBLE}" =~ ^[1-9][0-9]*$ ]] || { echo 'TIMEOUT_CRUCIBLE must be a positive decimal integer' >&2; exit 1; }
[[ "${SCENARIO}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'SCENARIO contains unsafe characters' >&2; exit 1; }
[[ "${EDPM_HOST}" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo 'EDPM_HOST contains unsafe characters' >&2; exit 1; }
[[ "${FRAME_SIZES}" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo 'FRAME_SIZES contains unsafe characters' >&2; exit 1; }

SSH_ARGS=(
  -i "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)
jumphost=$(<"${CLUSTER_PROFILE_DIR}/address")
bastion=$(<"${CLUSTER_PROFILE_DIR}/bastion")
[[ "${jumphost}" =~ ^[A-Za-z0-9._:-]+$ && "${bastion}" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  { echo 'SSH host contains unsafe characters' >&2; exit 1; }

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" root@"${jumphost}" bash -s -- "${bastion}" "${SCENARIO}" "${TIMEOUT_CRUCIBLE}" "${EDPM_HOST}" "${FRAME_SIZES}" <<'REMOTE'
set -o errexit
set -o nounset
set -o pipefail

bastion="$1"
scenario="$2"
timeout_crucible="$3"
edpm_host="$4"
frame_sizes="$5"
workspace=/home/zuul/netperf-rhoso18-nfv-e2e-validation
log_file=/tmp/nfv-e2e-crucible.log
SSH_ARGS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" zuul@"${bastion}" bash -s -- "${scenario}" "${timeout_crucible}" "${edpm_host}" "${frame_sizes}" "${workspace}" "${log_file}" <<'INNER'
set -o errexit
set -o nounset
set -o pipefail

scenario="$1"
timeout_crucible="$2"
edpm_host="$3"
frame_sizes="$4"
workspace="$5"
log_file="$6"

umask 077
tmp_log=''
if ! tmp_log=$(mktemp "${log_file}.XXXXXX") ||
  ! chmod 600 -- "${tmp_log}" ||
  ! mv -T -- "${tmp_log}" "${log_file}"; then
  [[ -z "${tmp_log}" ]] || rm -f -- "${tmp_log}"
  echo 'NFV_E2E_LOG_SETUP=failed'
  exit 1
fi

if ! cd -- "${workspace}"; then
  echo 'NFV_E2E_WORKSPACE=unavailable'
  exit 1
fi
set +o errexit
make e2e-crucible \
  "SCENARIO=${scenario}" \
  LAB_ENV=~/nfv-e2e/lab-init.env \
  E2E_EXTRA="--timeout-crucible ${timeout_crucible} --edpm-host ${edpm_host} --frame-sizes ${frame_sizes}" \
  2>&1 | tee "${log_file}"
pipeline_status=("${PIPESTATUS[@]}")
set -o errexit
workload_status="${pipeline_status[0]}"
capture_status="${pipeline_status[1]}"
printf 'NFV_E2E_TERMINAL=1\nNFV_E2E_WORKLOAD_EXIT=%s\nNFV_E2E_CAPTURE_EXIT=%s\n' \
  "${workload_status}" "${capture_status}"
if (( capture_status != 0 )); then
  exit "${capture_status}"
fi
exit "${workload_status}"
INNER
REMOTE
