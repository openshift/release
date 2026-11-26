#!/bin/bash
set -euo pipefail
umask 077
host=${ASSISTED_QE_HOST:?No host lease}
[[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]]
[[ "$QE_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
[[ "$QE_RUNNER_REF" =~ ^[0-9a-f]{40}$ ]]
[[ "$QE_RUNNER_REPO" == https://* ]]
[[ "$QE_PROFILE" =~ ^ci/prow/profiles/[a-zA-Z0-9_./-]+\.yaml$ && "$QE_PROFILE" != *..* ]]
# Administrators enable only hosts exclusively handed over from Jenkins.
grep -Fxq "$host" /var/run/assisted-qe/enabled-hosts
cat > "${SHARED_DIR}/qe-ssh.sh" <<'HELPER'
set -euo pipefail
umask 077
key=$(mktemp)
cp /var/run/assisted-qe/ssh-privatekey "$key"
chmod 600 "$key"
trap 'rm -f "$key"' EXIT
ssh_options=(-i "$key" -o BatchMode=yes -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/var/run/assisted-qe/known_hosts
    -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
host=$(cat "${SHARED_DIR}/qe-host")
ssh_user=$(cat "${SHARED_DIR}/qe-user")
# Commands are constructed locally with quoted, validated paths.
# shellcheck disable=SC2029
qe_ssh() { ssh "${ssh_options[@]}" "${ssh_user}@${host}" "$@"; }
qe_stop() {
    local work command
    work=$(cat "${SHARED_DIR}/qe-workspace")
    [[ "$work" =~ ^/home/[a-z_][a-z0-9_-]*/prow-assisted-qe/run\.[[:alnum:]]+$ ]]
    printf -v command 'bash -s -- %q' "$work"
    qe_ssh "$command" <<'STOP'
set -euo pipefail
work=$1
if [[ -f "$work/active.pid" ]]; then
    read -r pid < "$work/active.pid"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]
    if kill -0 "$pid" 2>/dev/null; then
        # Refuse to kill a recycled PID unrelated to this run.
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F "$work/" > /dev/null
        sudo -n kill -TERM -- "-$pid"
        sleep 5
        sudo -n kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    rm -f "$work/active.pid"
fi
STOP
}
qe_remote() {
    local phase=$1 duration=$2 work command rc=0
    work=$(cat "${SHARED_DIR}/qe-workspace") || return
    [[ "$work" =~ ^/home/[a-z_][a-z0-9_-]*/prow-assisted-qe/run\.[[:alnum:]]+$ ]] || return 1
    # Keep downstream logs on the host/Datahub, never in public Prow artifacts.
    qe_ssh "umask 077; cat > '$work/$phase.sh'" <<EOF || return
#!/bin/bash
set -euo pipefail
cd '$work'
source ./job.env
$(cat)
EOF
    printf -v command 'bash -s -- %q %q %q' "$work" "$phase" "$duration"
    qe_ssh "$command" <<'SUPERVISOR' || rc=$?
set -euo pipefail
cd "$1"
mkdir -p logs
# A process group and a host-side deadline also protect against pod/SSH loss.
setsid timeout --signal=TERM --kill-after=30s "$3" bash "$1/$2.sh" > "logs/$2.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > active.pid
status=0
wait "$pid" || status=$?
rm -f active.pid
exit "$status"
SUPERVISOR
    echo "${phase}: exit ${rc}; full logs remain on the host/Datahub."
    return "$rc"
}
HELPER
printf '%s\n' "$host" > "${SHARED_DIR}/qe-host"
printf '%s\n' "$QE_SSH_USER" > "${SHARED_DIR}/qe-user"
source "${SHARED_DIR}/qe-ssh.sh"
work=$(qe_ssh "umask 077; mkdir -p /home/$QE_SSH_USER/prow-assisted-qe; mktemp -d /home/$QE_SSH_USER/prow-assisted-qe/run.XXXXXXXX")
[[ "$work" =~ ^/home/[a-z_][a-z0-9_-]*/prow-assisted-qe/run\.[[:alnum:]]+$ ]]
printf '%s\n' "$work" > "${SHARED_DIR}/qe-workspace"
{
    printf 'export WORKSPACE=%q\n' "$work"
    printf 'export HOST=%q\n' "$host"
    printf 'export QE_RUNNER_REPO=%q\n' "$QE_RUNNER_REPO"
    printf 'export QE_RUNNER_REF=%q\n' "$QE_RUNNER_REF"
    printf 'export QE_PROFILE=%q\n' "$QE_PROFILE"
    printf 'export QE_OCP_VERSION=%q\n' "$QE_OCP_VERSION"
    printf 'export OPENSHIFT_RELEASE_IMAGE=%q\n' "${RELEASE_IMAGE_LATEST:?}"
    printf 'export QE_PUBLISH_RESULTS=%q\n' "$QE_PUBLISH_RESULTS"
    printf 'export JOB_NAME=%q\n' "${JOB_NAME:?}"
    printf 'export BUILD_NUMBER=%q\n' "${BUILD_ID:?}"
    printf 'export BUILD_URL=%q\n' "https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/${JOB_NAME}/${BUILD_ID}"
} | qe_ssh "umask 077; cat > '$work/job.env'"
qe_ssh "mkdir -m 700 '$work/secrets'"
# Only workload credentials are transferred. SSH credentials stay in the pod.
for credential in /var/run/assisted-qe/*; do
    [[ -f "$credential" ]] || continue
    name=${credential##*/}
    case "$name" in ssh-privatekey|known_hosts|enabled-hosts) continue ;; esac
    [[ "$name" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$ ]]
    qe_ssh "umask 077; cat > '$work/secrets/$name'" < "$credential"
done
qe_remote bootstrap 15m <<'REMOTE'
sudo -n true
git clone "$QE_RUNNER_REPO" "$WORKSPACE/ocp-edge-ci"
git -C "$WORKSPACE/ocp-edge-ci" fetch origin "$QE_RUNNER_REF"
git -C "$WORKSPACE/ocp-edge-ci" checkout --detach "$QE_RUNNER_REF"
python=''
for candidate in /usr/bin/python3.12 /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
        python=$candidate
        break
    fi
done
[[ -n "$python" ]] || { echo 'The runner requires Python >= 3.8'; exit 1; }
"$python" -m venv "$WORKSPACE/runner-venv"
"$WORKSPACE/runner-venv/bin/pip" install -r "$WORKSPACE/ocp-edge-ci/ci/prow/requirements.txt"
"$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" init \
    --profile "$QE_PROFILE" --workspace "$WORKSPACE"
REMOTE
qe_remote prepare "$QE_PREPARE_TIMEOUT" <<'REMOTE'
exec "$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" prepare --workspace "$WORKSPACE"
REMOTE
