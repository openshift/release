#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "$*" >&2
  exit 1
}

# /src is the tested checkout baked into ansible-test-runner, including Prow's merge.
cd /src
revision=$(git rev-parse HEAD)
# A rehearsal builds the image from appliance main, which may predate the runner.
[[ -f image/tools/test-runtime.sh ]] || fail "tested appliance source has no image/tools/test-runtime.sh"
authfile=/var/run/secrets/ci-pull-credentials/.dockerconfigjson
[[ -s $authfile ]] || fail "registry auth file is missing or empty: $authfile"
mkdir -p "$ARTIFACT_DIR"
printf '%s\n' "$revision" >"$ARTIFACT_DIR/source-revision.txt"

local_work=$(mktemp -d)
remote_work=""
remote_pid=""
remote_log_fd=""
remote_log_pid=""
runtime_in_progress=false
ip=$(cat "${SHARED_DIR}/public_address")
user=$(cat "${SHARED_DIR}/ssh_user")
ssh_options=(-i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" -o BatchMode=yes -o IdentitiesOnly=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$local_work/known_hosts")
# Short commands get a local deadline: keepalives catch a dead host, not a stuck command.
remote_deadline=2m
remote() {
  # Commands are deliberately assembled for execution by the remote shell.
  # shellcheck disable=SC2029
  timeout --kill-after=10s "$remote_deadline" ssh "${ssh_options[@]}" "${user}@${ip}" "$@"
}

# Bash runs a trap only after a foreground command exits, and ci-operator signals only
# this shell. Wait on a background SSH so cancellation reaches cleanup promptly.
remote_logged() {
  local log=$1 status=0 log_status=0
  shift
  exec {remote_log_fd}> >(tee "$log")
  remote_log_pid=$!
  # shellcheck disable=SC2029
  (exec ssh "${ssh_options[@]}" "${user}@${ip}" "$@") >&"$remote_log_fd" 2>&1 &
  remote_pid=$!
  wait "$remote_pid" || status=$?
  remote_pid=""
  exec {remote_log_fd}>&-
  remote_log_fd=""
  wait "$remote_log_pid" || log_status=$?
  remote_log_pid=""
  if [[ $status -eq 0 ]]; then status=$log_status; fi
  return "$status"
}

cleanup() {
  status=$?
  # Guard before dropping the EXIT trap: a second signal must not cut cleanup short.
  trap : INT TERM
  trap - EXIT
  set +e
  if [[ -n $remote_pid ]]; then
    kill "$remote_pid" 2>/dev/null
    wait "$remote_pid"
  fi
  if [[ -n $remote_log_fd ]]; then exec {remote_log_fd}>&-; fi
  if [[ -n $remote_log_pid ]]; then
    kill "$remote_log_pid" 2>/dev/null
    wait "$remote_log_pid"
  fi
  stop_status=0
  if [[ $runtime_in_progress == true ]]; then
    # SSH termination does not stop remote work. Let its traps finish before collection.
    # The marker also prevents a delayed launch from starting after cancellation.
    printf -v stop_command '%q ' sudo -n timeout --kill-after=5s 190s bash -ec '
touch "$1/cancelled"
# Without a PID, retain the marker until VM teardown: launch may still be pending.
[[ -s "$1/runtime.pid" ]] || exit 1
read -r pid < "$1/runtime.pid"
kill -TERM "$pid" 2>/dev/null || exit 0
while kill -0 "$pid" 2>/dev/null; do sleep 1; done
' bash "$remote_work"
    remote_deadline=200s
    remote "$stop_command"
    stop_status=$?
  fi
  remote_deadline=45s
  if [[ $stop_status -ne 0 ]]; then
    echo "could not confirm the remote runtime stopped; retaining its files for VM deprovisioning" >&2
    if [[ $status -eq 0 ]]; then status=$stop_status; fi
  elif [[ -n $remote_work ]]; then
    # Remove credentials before collecting only the explicitly selected output directory.
    remote "sudo -n rm -f '$remote_work/auth.json'"
    auth_status=$?
    remote "sudo -n tar -C '$remote_work/artifacts' -czf - ." >"$ARTIFACT_DIR/runtime-artifacts.tar.gz"
    collection_status=$?
    remote "sudo -n rm -rf '$remote_work'"
    cleanup_status=$?
    if [[ $status -eq 0 && $auth_status -ne 0 ]]; then status=$auth_status; fi
    if [[ $status -eq 0 && $collection_status -ne 0 ]]; then status=$collection_status; fi
    if [[ $status -eq 0 && $cleanup_status -ne 0 ]]; then status=$cleanup_status; fi
  fi
  rm -rf "$local_work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Cancellation can close the output reader before cleanup reports an error.
trap '' PIPE

# OpenSSH requires a passwd entry; OpenShift can assign an arbitrary UID.
if ! getent passwd "$(id -u)" >/dev/null; then
  cp /etc/passwd "$local_work/passwd"
  printf 'ega-ci:x:%s:%s:CI user:%s:/bin/bash\n' "$(id -u)" "$(id -g)" "$HOME" >>"$local_work/passwd"
  export NSS_WRAPPER_PASSWD="$local_work/passwd" NSS_WRAPPER_GROUP=/etc/group
  export LD_PRELOAD="/usr/lib64/libnss_wrapper.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# Bound setup separately; the independent remote timeout also survives an SSH disconnect.
# Install first: the source transfer and artifact collection both need tar on the VM.
remote_logged "$ARTIFACT_DIR/host-setup.log" 'sudo -n timeout --kill-after=1m 10m dnf install -y podman tar'
candidate=$(remote 'umask 077; mktemp -d /tmp/ega-runtime.XXXXXXXX')
[[ $candidate =~ ^/tmp/ega-runtime\.[[:alnum:]]{8}$ ]] || fail "unexpected remote work directory: $candidate"
remote_work=$candidate
remote "mkdir '$remote_work/source' '$remote_work/artifacts'"
# Archive exactly HEAD; do not fetch a mutable PR head or reuse the release PR number.
git archive --format=tar HEAD | remote "tar -C '$remote_work/source' -xf -"
# The builds pull only from registry.redhat.io; send no other registry's token to the VM.
python3 -c 'import json, sys
entry = json.load(open(sys.argv[1])).get("auths", {}).get("registry.redhat.io")
if entry is None:
    sys.exit("registry auth file has no registry.redhat.io entry")
json.dump({"auths": {"registry.redhat.io": entry}}, sys.stdout)' "$authfile" |
  remote "umask 077; cat > '$remote_work/auth.json'"

runner_env=("REGISTRY_AUTH_FILE=$remote_work/auth.json" "ARTIFACT_DIR=$remote_work/artifacts"
  "SOURCE_REVISION=$revision")
for name in BOOTC_BASE EGA_PAYLOAD_RHEL10_FRR_REPOSITORY EGA_PAYLOAD_RHEL10_FRR_TAG \
  EGA_PAYLOAD_RHEL10_FRR_DIGEST EGA_PAYLOAD_RHEL10_NODE_EXPORTER_REPOSITORY \
  EGA_PAYLOAD_RHEL10_NODE_EXPORTER_TAG EGA_PAYLOAD_RHEL10_NODE_EXPORTER_DIGEST; do
  if [[ -n ${!name:-} ]]; then runner_env+=("$name=${!name}"); fi
done
printf -v command '%q ' sudo -n env "${runner_env[@]}" bash -ec '
printf "%s\n" "$$" > "$1/runtime.pid"
[[ ! -e "$1/cancelled" ]] || exit 143
shift
exec timeout --kill-after=3m 45m "$@"
' bash "$remote_work" bash "$remote_work/source/image/tools/test-runtime.sh"
runtime_in_progress=true
runtime_status=0
remote_logged "$ARTIFACT_DIR/runtime.log" "cd '$remote_work/source' && $command" || runtime_status=$?
# A signal or disconnect can end local SSH while remote work continues.
if [[ $runtime_status -lt 128 ]]; then runtime_in_progress=false; fi
if [[ $runtime_status -eq 124 || $runtime_status -eq 137 ]]; then
  echo "appliance runtime timed out or was killed (status $runtime_status); see runtime.log and collected artifacts" >&2
fi
exit "$runtime_status"
