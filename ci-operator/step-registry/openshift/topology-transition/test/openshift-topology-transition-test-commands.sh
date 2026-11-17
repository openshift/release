#!/bin/bash
set -euo pipefail

if [[ ! "${TEST_SUITE}" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ || ! "${TEST_SUITE_TIMEOUT}" =~ ^[1-9][0-9]*[smh]$ ]]; then
  echo 'TEST_SUITE must be a suite name and TEST_SUITE_TIMEOUT a positive duration (s, m, or h)' >&2
  exit 1
fi

# SSH requires an entry for the random UID assigned to this container.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo '/etc/passwd is not writable, and no user exists for the current UID.' >&2
    exit 1
  fi
fi

SSHOPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir=$(cat "${SHARED_DIR}/remote_workdir")

# Like the image-based lanes, run the job's test image binary on the EC2 host.
printf -v remote_args '%q ' "${workdir}" "${TESTS_PULL_REF}" "${TEST_SUITE}" "${TEST_SUITE_TIMEOUT}" \
  "${TARGET_CONTROL_PLANE_TOPOLOGY}" "${TARGET_INFRASTRUCTURE_TOPOLOGY}" \
  "${TARGET_CONTROL_PLANE_NODES}" "${TARGET_COMPUTE_NODES}" "${TARGET_ARBITER_NODES}" \
  "${TARGET_CONTROL_PLANE_NODES_SCHEDULABLE}"
ssh "${SSHOPTS[@]}" "${remote}" "sudo bash -s -- ${remote_args}" <<'REMOTE'
set -euo pipefail
cd "$1"
trap 'chown -R ec2-user:ec2-user .' EXIT
tests_image=$2
suite=$3
suite_timeout=$4
export TARGET_CONTROL_PLANE_TOPOLOGY=$5 TARGET_INFRASTRUCTURE_TOPOLOGY=$6
export TARGET_CONTROL_PLANE_NODES=$7 TARGET_COMPUTE_NODES=$8 TARGET_ARBITER_NODES=$9
export TARGET_CONTROL_PLANE_NODES_SCHEDULABLE=${10}
# shellcheck source=/dev/null
source common.sh

oc image extract --registry-config=pull-secret "${tests_image}" --path=/usr/bin/openshift-tests:bin --confirm
artifacts="results/${suite//\//-}"
mkdir -p "${artifacts}"
# Origin retains its 45/195-minute suite limits and five-minute CLI limit.
timeout --signal=TERM --kill-after=2m "${suite_timeout}" openshift-tests run "${suite}" \
  -o "${artifacts}/e2e.log" --junit-dir="${artifacts}/junit" 2>&1 | tee "${artifacts}/output.log"
REMOTE
