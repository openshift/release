#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${SCENARIO:?SCENARIO must be set}"
: "${EDPM_HOST:?EDPM_HOST must be set}"

[[ "${SCENARIO}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'SCENARIO contains unsafe characters' >&2; exit 1; }
[[ "${EDPM_HOST}" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo 'EDPM_HOST contains unsafe characters' >&2; exit 1; }

SSH_ARGS=(
  -i "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
)
jumphost=$(<"${CLUSTER_PROFILE_DIR}/address")
bastion=$(<"${CLUSTER_PROFILE_DIR}/bastion")
[[ "${jumphost}" =~ ^[A-Za-z0-9._:-]+$ && "${bastion}" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  { echo 'SSH host contains unsafe characters' >&2; exit 1; }

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" root@"${jumphost}" bash -s -- "${bastion}" "${SCENARIO}" "${EDPM_HOST}" <<'REMOTE'
set -o errexit
set -o nounset
set -o pipefail

bastion="$1"
scenario="$2"
edpm_host="$3"
workspace=/home/zuul/netperf-rhoso18-nfv-e2e-validation
log_file=/tmp/nfv-e2e-deployment.log
SSH_ARGS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
)

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" zuul@"${bastion}" bash -s -- "${scenario}" "${edpm_host}" "${workspace}" "${log_file}" <<'INNER'
set -o errexit
set -o nounset
set -o pipefail

scenario="$1"
edpm_host="$2"
workspace="$3"
log_file="$4"

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
make e2e "SCENARIO=${scenario}" CLEAN_FIRST=1 LAB_ENV=~/nfv-e2e/lab-init.env \
  E2E_EXTRA="--skip-crucible --edpm-host ${edpm_host}" 2>&1 | tee "${log_file}"
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
