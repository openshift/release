#!/bin/bash
set -euo pipefail

report_result() {
  local result=$?

  if (( result == 0 )); then
    echo 'Topology test step: completed successfully'
  else
    printf 'Topology test step: failed (exit %s)\n' "${result}" >&2
  fi

  exit "${result}"
}
trap report_result EXIT

echo 'Topology test step: starting'

if [[ ! "${TEST_SUITE}" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ || ! "${TEST_SUITE_TIMEOUT}" =~ ^[1-9][0-9]*[smh]$ ]]; then
  echo 'TEST_SUITE must be a suite name and TEST_SUITE_TIMEOUT a positive duration (s, m, or h)' >&2
  exit 1
fi
printf 'Test suite: %s\n' "${TEST_SUITE}"

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

suite_artifacts=${TEST_SUITE//\//-}
mkdir -p "${ARTIFACT_DIR}/${suite_artifacts}"

# Like the image-based lanes, run the job's test image binary on the EC2 host.
printf -v remote_args '%q ' "${workdir}" "${TESTS_PULL_REF}" "${TEST_SUITE}" "${TEST_SUITE_TIMEOUT}" \
  "${TARGET_CONTROL_PLANE_TOPOLOGY}" "${TARGET_INFRASTRUCTURE_TOPOLOGY}" \
  "${TARGET_CONTROL_PLANE_NODES}" "${TARGET_COMPUTE_NODES}" "${TARGET_ARBITER_NODES}" \
  "${TARGET_CONTROL_PLANE_NODES_SCHEDULABLE}"
echo 'Preparing the test binary on the host'
set +e
ssh "${SSHOPTS[@]}" "${remote}" "sudo bash -s -- ${remote_args}" <<'REMOTE'
set -euo pipefail
cd "$1"
download_dir=''
restore_ownership() {
  local result=$?

  if [[ -n "${download_dir}" ]] && ! rm -rf -- "${download_dir}" 2>/dev/null; then
    echo 'Could not remove the temporary test binary download' >&2
    if (( result == 0 )); then
      result=1
    fi
  fi

  if ! chown -R ec2-user:ec2-user . 2>/dev/null; then
    echo 'Could not restore ownership of remote files' >&2
    if (( result == 0 )); then
      result=1
    fi
  fi

  exit "${result}"
}
trap restore_ownership EXIT
tests_image=$2
suite=$3
suite_timeout=$4
export TARGET_CONTROL_PLANE_TOPOLOGY=$5 TARGET_INFRASTRUCTURE_TOPOLOGY=$6
export TARGET_CONTROL_PLANE_NODES=$7 TARGET_COMPUTE_NODES=$8 TARGET_ARBITER_NODES=$9
export TARGET_CONTROL_PLANE_NODES_SCHEDULABLE=${10}
artifacts="results/${suite//\//-}"
rm -rf "${artifacts}"
mkdir -p "${artifacts}/junit"
# shellcheck source=/dev/null
source common.sh

# A failed layer download can leave a partial file. Publish only a complete
# extraction, and never fall back to a binary left by an earlier suite.
download_dir=$(mktemp -d "${PWD}/.tests-download.XXXXXX")
for attempt in 1 2 3; do
  printf 'Test binary download: attempt %s of 3 (2 minute limit per attempt)\n' "${attempt}"
  rm -f -- "${download_dir}/openshift-tests"
  if timeout --kill-after=10s 2m oc image extract --registry-config=pull-secret "${tests_image}" \
      --path="/usr/bin/openshift-tests:${download_dir}" --confirm >/dev/null 2>&1; then
    extract_result=0
  else
    extract_result=$?
  fi

  if (( extract_result == 0 )) && [[ -s "${download_dir}/openshift-tests" ]]; then
    if ! chmod 755 "${download_dir}/openshift-tests" 2>/dev/null ||
      ! mv -f -- "${download_dir}/openshift-tests" bin/openshift-tests 2>/dev/null; then
      echo 'Could not publish the downloaded test binary' >&2
      exit 1
    fi
    echo 'Test binary download completed successfully'
    break
  fi
  if (( extract_result == 0 )); then
    extract_result=1
  fi
  if (( attempt == 3 )); then
    printf 'Test binary download failed after 3 attempts (exit %s)\n' "${extract_result}" >&2
    exit "${extract_result}"
  fi

  printf 'Test binary download failed (exit %s); retrying in 10s\n' "${extract_result}"
  sleep 10
done

printf 'Running test suite: %s\n' "${suite}"
# Origin retains its 45/195-minute suite limits and five-minute CLI limit.
timeout --signal=TERM --kill-after=2m "${suite_timeout}" openshift-tests run "${suite}" \
  -o "${artifacts}/e2e.log" --junit-dir="${artifacts}/junit" 2>&1 | tee "${artifacts}/output.log"
REMOTE
suite_result=$?
set -e

# Each test step publishes its own logs and JUnit, even when the suite fails.
echo 'Copying test logs and JUnit results to the step artifacts'
artifact_result=0
scp "${SSHOPTS[@]}" -r "${remote}:${workdir}/results/${suite_artifacts}/." \
  "${ARTIFACT_DIR}/${suite_artifacts}/" 2>/dev/null || artifact_result=$?
if (( artifact_result != 0 )); then
  printf 'Could not copy test artifacts (exit %s)\n' "${artifact_result}" >&2
fi

if (( suite_result != 0 )); then
  exit "${suite_result}"
fi
exit "${artifact_result}"
