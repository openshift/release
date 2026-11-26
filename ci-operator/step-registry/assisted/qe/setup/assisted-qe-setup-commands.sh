#!/bin/bash
set -euo pipefail
umask 077
host=${ASSISTED_QE_HOST:?No host lease}
[[ "$QE_OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]]
[[ "$QE_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
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
# Copy only explicitly declared Prow parameters, never the pod's full environment.
qe_export() {
    local work name
    work=$(cat "${SHARED_DIR}/qe-workspace")
    [[ "$work" =~ ^/home/[a-z_][a-z0-9_-]*/prow-assisted-qe/run\.[[:alnum:]]+$ ]]
    for name in "$@"; do
        [[ "$name" =~ ^[A-Z_][A-Z_0-9]*$ ]] || return 1
        case "$name" in WORKSPACE|HOST|HOME|PATH|QE_SECRETS_DIR) return 1 ;; esac
    done
    { for name in "$@"; do printf 'export %s=%q\n' "$name" "${!name}"; done; } |
        qe_ssh "cat >> '$work/job.env'"
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
    printf 'export QE_SECRETS_DIR=%q\n' "$work/secrets"
    printf 'export QE_OCP_VERSION=%q\n' "$QE_OCP_VERSION"
    printf 'export OPENSHIFT_RELEASE_IMAGE=%q\n' "${RELEASE_IMAGE_LATEST:?}"
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
qe_remote bootstrap 10m <<'REMOTE'
sudo -n true
for tool in git timeout setsid; do command -v "$tool"; done
python=''
for candidate in /usr/bin/python3.12 /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 6))'; then
        python=$candidate
        break
    fi
done
[[ -n "$python" ]] || { echo 'Results processing requires Python >= 3.6'; exit 1; }
printf 'export QE_PYTHON=%q\n' "$python" >> "$WORKSPACE/job.env"
mkdir -p "$WORKSPACE/results" "$WORKSPACE/public"
cat > "$WORKSPACE/results.py" <<'PYTHON'
"""Check JUnit and emit status-only public artifacts; raw output stays internal."""
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET

def check(work):
    reports = sorted((work / 'results').glob('*.xml'))
    if (work / 'results/failed').exists():
        raise ValueError('Test command recorded a failure marker')
    if not reports:
        raise ValueError('No JUnit reports were produced')
    executed = 0
    for report in reports:
        original = ET.parse(str(report))
        if original.findall('.//failure') or original.findall('.//error'):
            raise ValueError('JUnit contains failed tests')
        for suite in original.iter('testsuite'):
            if int(suite.get('failures', 0)) or int(suite.get('errors', 0)):
                raise ValueError('JUnit contains a failed suite')
        executed += sum(case.find('skipped') is None for case in original.iter('testcase'))
    if not executed:
        raise ValueError('No test cases executed')

def publish(work):
    public = work / 'public'
    if public.exists():
        shutil.rmtree(str(public))
    public.mkdir()
    for index, report in enumerate(sorted((work / 'results').glob('*.xml'))):
        original = ET.parse(str(report))
        suite = ET.Element('testsuite', name='assisted-qe')
        for number, case in enumerate(original.iter('testcase')):
            item = ET.SubElement(suite, 'testcase', name='case-{}'.format(number), classname='assisted.qe')
            for tag in ('failure', 'error', 'skipped'):
                if case.find(tag) is not None:
                    ET.SubElement(item, tag, message='See internal host artifacts for details')
        suite.set('tests', str(len(suite)))
        for tag, attr in [('failure', 'failures'), ('error', 'errors'), ('skipped', 'skipped')]:
            suite.set(attr, str(len(suite.findall('testcase/' + tag))))
        ET.ElementTree(suite).write(str(public / ('junit_{}.xml'.format(index))), encoding='utf-8', xml_declaration=True)

if __name__ == '__main__':
    try:
        {'check': check, 'publish': publish}[sys.argv[1]](Path(sys.argv[2]))
    except (ValueError, OSError, ET.ParseError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
PYTHON
REMOTE
