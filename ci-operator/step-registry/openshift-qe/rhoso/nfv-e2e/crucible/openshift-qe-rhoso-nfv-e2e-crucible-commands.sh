#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

jumphost=$(<"${CLUSTER_PROFILE_DIR}/address")
bastion=$(<"${CLUSTER_PROFILE_DIR}/bastion")
child_pid=
signal_pending=false

terminate_child() {
  if [[ -n "${child_pid}" ]]; then
    kill -TERM -- "-${child_pid}" 2>/dev/null ||
      kill -TERM "${child_pid}" 2>/dev/null || :
  fi
}
forward_signal() {
  signal_pending=true
  terminate_child
}
trap forward_signal TERM INT HUP

SSH_ARGS=(
  -i "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)

# shellcheck disable=SC2087
setsid ssh "${SSH_ARGS[@]}" root@"${jumphost}" env \
  BASTION="${bastion}" \
  SCENARIO="${SCENARIO}" \
  TIMEOUT_CRUCIBLE="${TIMEOUT_CRUCIBLE}" \
  EDPM_HOST="${EDPM_HOST}" \
  FRAME_SIZES="${FRAME_SIZES}" \
  bash -s <<'EOF' &
set -o errexit
set -o nounset
set -o pipefail
child_pid=
signal_pending=false

terminate_child() {
  if [[ -n "${child_pid}" ]]; then
    kill -TERM -- "-${child_pid}" 2>/dev/null ||
      kill -TERM "${child_pid}" 2>/dev/null || :
  fi
}
forward_signal() {
  signal_pending=true
  terminate_child
}
trap forward_signal TERM INT HUP
SSH_ARGS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)

# shellcheck disable=SC2087
setsid ssh "${SSH_ARGS[@]}" zuul@"${BASTION}" env \
  SCENARIO="${SCENARIO}" \
  TIMEOUT_CRUCIBLE="${TIMEOUT_CRUCIBLE}" \
  EDPM_HOST="${EDPM_HOST}" \
  FRAME_SIZES="${FRAME_SIZES}" \
  bash -s <<'REMOTE' &
set -o errexit
set -o nounset
set -o pipefail

child_pid=
signal_pending=false

terminate_child() {
  if [[ -n "${child_pid}" ]]; then
    kill -TERM -- "-${child_pid}" 2>/dev/null ||
      kill -TERM "${child_pid}" 2>/dev/null || :
  fi
}
forward_signal() {
  signal_pending=true
  terminate_child
}
trap forward_signal TERM INT HUP
cd /home/zuul/netperf-rhoso18-nfv-e2e-validation
make e2e-crucible \
  "SCENARIO=${SCENARIO}" \
  LAB_ENV=~/nfv-e2e/lab-init.env \
  E2E_EXTRA="--timeout-crucible ${TIMEOUT_CRUCIBLE} --edpm-host ${EDPM_HOST} --frame-sizes ${FRAME_SIZES}" &
child_pid=$!
if [[ "${signal_pending}" == true ]]; then
  terminate_child
fi
status=0
wait "${child_pid}" || status=$?
if [[ "${signal_pending}" == true ]]; then
  exit 143
fi
exit "${status}"
REMOTE
child_pid=$!
if [[ "${signal_pending}" == true ]]; then
  terminate_child
fi
status=0
wait "${child_pid}" || status=$?
if [[ "${signal_pending}" == true ]]; then
  exit 143
fi
exit "${status}"
EOF
child_pid=$!
if [[ "${signal_pending}" == true ]]; then
  terminate_child
fi
status=0
wait "${child_pid}" || status=$?
if [[ "${signal_pending}" == true ]]; then
  exit 143
fi
exit "${status}"
