#!/bin/bash
set -euo pipefail

gather_skipped=false
transfer_archive=''

finish_step() {
  local result=$?

  trap - EXIT
  if [[ -n "${transfer_archive}" ]]; then
    rm -f -- "${transfer_archive}" || echo 'Gather warning: could not remove the temporary archive' >&2
  fi

  if (( result != 0 )); then
    printf 'Gather step: failed (exit %s)\n' "${result}" >&2
  elif [[ "${gather_skipped}" == true ]]; then
    echo 'Gather step: skipped (no EC2 host handoff)'
  else
    echo 'Gather step: completed successfully'
  fi

  exit "${result}"
}
trap finish_step EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo 'Gather step: starting'

# The host may not exist if EC2 allocation failed. Cleanup still runs next.
if [[ ! -s "${SHARED_DIR}/remote_workdir" || ! -s "${SHARED_DIR}/public_address" ]]; then
  gather_skipped=true
  exit 0
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
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" <<'REMOTE'
set -uo pipefail
cd "$1" || exit 1
mkdir -p results/host results/cluster || exit 1
warnings=0

warn() {
  warnings=$((warnings + 1))
  printf 'Gather warning: %s\n' "$1" >&2
}

export PATH="${PWD}/bin:${PATH}"
export KUBECONFIG="${PWD}/install/auth/kubeconfig"

echo 'Collecting VM and host status'

# Copy only known public files. Install assets and Ignition contain credentials.
cp inventory.json state.json results/host/ 2>/dev/null || warn 'some host state files are unavailable'
virsh list --all > results/host/vms.txt 2>/dev/null || warn 'could not list VMs'
network=$(jq -er '.network // "transitionbm"' state.json 2>/dev/null) || network=transitionbm
virsh net-dumpxml "${network}" > results/host/network.xml 2>/dev/null || warn 'could not collect VM network state'
journalctl --no-pager -u libvirtd -u virtqemud -u virtnetworkd -u haproxy > results/host/services.log 2>/dev/null || warn 'could not collect host service logs'
cp /var/log/libvirt/qemu/*.log results/host/ 2>/dev/null || warn 'VM logs are unavailable'

echo 'Collecting a filtered dev-scripts error summary'
# Dev-scripts logs include shell tracing and credential/config dumps. Extract
# diagnostics before writing artifacts; never copy the raw logs or nearby lines.
if ! python3 - 2>/dev/null <<'DEV_SCRIPTS_ERRORS'
from collections import deque
import json
from pathlib import Path
import re

phases = (
    'make', '01_agent_requirements', '01_install_requirements', '02_configure_host',
    '03_agent_build_installer', '03_build_installer', '04_agent_prepare_release',
    '05_agent_configure', '06_agent_create_cluster',
)
phase, exit_code = 'unknown', 'unknown'
status = Path('results/host/dev-scripts-status.txt')
if status.is_file():
    for line in status.read_text(errors='replace').splitlines():
        key, _, value = line.partition('=')
        if key == 'phase' and value in phases:
            phase = value
        if key == 'exit' and re.fullmatch(r'[0-9]{1,3}', value) and int(value) <= 255:
            exit_code = str(int(value))

sources = [('make', Path('dev-scripts.log'))]
if phase in phases[1:]:
    # Match the known phase only. Keep names, paths and command arguments private.
    sources.extend((phase, path) for path in sorted(Path('dev-scripts/logs').glob(phase + '-*.log'))[-2:])

ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
timestamp = re.compile(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+')
diagnostic = re.compile(
    r'\b(?:error|fatal|failed|failure|panic|exception|timed out|permission denied|'
    r'not found|no such file|unbound variable)\b|\b\w+(?:Error|Exception):', re.I)
sensitive = re.compile(
    r'\b(?:password|passwd|secret|auth|api[-_ ]?key|credentials?|pull[-_ ]?secret|authorization|bearer|token|'
    r'client[-_ ]?key|private[-_ ]?key|kubeconfig|dockerconfigjson|auths|'
    r'identitytoken|activation[-_ ]?key|subscription[-_ ]?manager[-_ ]?org)\b', re.I)
credential_assignment = re.compile(
    r'(?:^|[^\w])[-\w.]*(?:password|passwd|token|secret|auth|credential|key)[-\w.]*'
    r'["\']?\s*[:=]', re.I)
messages = deque(maxlen=80)
read_count, omitted = 0, 0

for label, path in sources:
    if not path.is_file() or path.is_symlink():
        continue

    read_count += 1
    # Bound reads even when make has produced hours of verbose output.
    with path.open('rb') as stream:
        stream.seek(0, 2)
        offset = max(0, stream.tell() - 4 * 1024 * 1024)
        stream.seek(offset)
        if offset:
            stream.readline()
        lines = stream.read().decode('utf-8', errors='replace').splitlines()

    for raw in lines:
        line = timestamp.sub('', ansi.sub('', raw).strip())
        if not line or line.startswith(('+', '++', '---', '>>>')):
            continue

        # Select only the message from structured loggers, never their fields.
        if line.startswith('{'):
            try:
                record = json.loads(line)
            except (ValueError, TypeError):
                continue
            if not isinstance(record, dict) or str(record.get('level', '')).lower() not in ('error', 'fatal', 'panic'):
                continue
            line = record.get('msg', record.get('message', ''))
            if not isinstance(line, str):
                continue
            cause = record.get('error')
            if isinstance(cause, str) and cause:
                line += '; cause: ' + cause
        elif re.search(r'\blevel=(?:error|fatal|panic)\b', line, re.I):
            fields = []
            for match in re.finditer(r'\b(msg|message|error)=("(?:\\.|[^"\\])*"|[^\s]+)', line):
                value = match.group(2)
                try:
                    fields.append(json.loads(value) if value.startswith('"') else value)
                except ValueError:
                    continue
            if not fields:
                continue
            line = '; cause: '.join(fields)
        elif not diagnostic.search(line) and not re.match(r'^make(?:\[\d+\])?: \*\*\*', line):
            continue

        # A diagnostic that embeds credential material is unsafe even if one
        # value could be masked: config dumps can span lines or contain JSON.
        if (sensitive.search(line) or credential_assignment.search(line) or
                re.search(r'\b[A-Z_][A-Z0-9_]*=', line) or any(char in line for char in '{}')):
            omitted += 1
            continue

        line = re.sub(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"\']+', '[URL]', line)
        line = re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b', '[ADDRESS]', line)
        line = re.sub(r'\b[0-9a-fA-F]*:[0-9a-fA-F:]+(?:%[\w.-]+)?\b', '[ADDRESS]', line)
        line = re.sub(r'(?<!\w)(?:/|\./|\.\./)[^\s:;,)\]"\']+', '[PATH]', line)
        line = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`[^`]*`', '[VALUE]', line)
        line = re.sub(r'\b[\w-]+(?:\.[\w-]+)+\b|\b(?:[\w-]+[_-])?(?:master|worker|infra)[_-]\d+\b', '[NAME]', line)
        line = re.sub(r'(?<!\w)[A-Za-z0-9_+/=-]{24,}(?!\w)', '[VALUE]', line)
        line = ''.join(char for char in line if char.isprintable())[:500]
        if line:
            item = f'{label}: {line}'
            if not messages or messages[-1] != item:
                messages.append(item)

report = [f'phase={phase}', f'exit={exit_code}', f'logs_read={read_count}',
          f'credential_or_config_diagnostics_omitted={omitted}']
report.extend(messages or ['No safe error diagnostics found in the available log tails.'])
Path('results/host/dev-scripts-errors.txt').write_text('\n'.join(report) + '\n')
print(f'Dev-scripts error summary saved: {read_count} logs checked, {len(messages)} diagnostics retained')
DEV_SCRIPTS_ERRORS
then
  warn 'could not collect the dev-scripts error summary'
fi

echo 'Collecting the redacted installer log'
if [[ -s install/.openshift_install.log ]]; then
  # Redact before writing artifacts; keep the surrounding log text intact.
  sed -E 's/(password: (\\?")?)[^"\\[:space:]]+/\1REDACTED/g' \
    install/.openshift_install.log > results/cluster/install.log || warn 'could not collect the installer log'
else
  echo 'Installer log is not available yet'
fi
if [[ -s "${KUBECONFIG}" ]]; then
  echo 'Collecting cluster state (up to 2 minutes per request)'
  timeout 2m oc get nodes,clusteroperators -o yaml > results/cluster/status.yaml 2>&1 || warn 'could not collect node and operator state'
  timeout 2m oc get infrastructure cluster -o yaml > results/cluster/infrastructure.yaml 2>&1 || warn 'could not collect infrastructure state'
  timeout 2m oc get events -A -o yaml > results/cluster/events.yaml 2>&1 || warn 'could not collect cluster events'
  echo 'Starting must-gather (20 minute limit)'
  timeout --kill-after=1m 20m oc adm must-gather --dest-dir=results/cluster/must-gather \
    > results/cluster/must-gather.log 2>&1 || warn 'must-gather did not complete successfully'
else
  echo 'Skipping cluster collection: no kubeconfig is available'
fi
printf 'Host and cluster collection finished with %s warnings\n' "${warnings}"

# One archive avoids an SSH round trip for every small must-gather file.
echo 'Packing collected files for transfer (5 minute limit)'
if ! timeout --kill-after=10s 5m tar -czf gather.tar.gz -C results . 2>/dev/null; then
  echo 'Could not pack the gathered files' >&2
  exit 1
fi
if ! chown ec2-user:ec2-user gather.tar.gz 2>/dev/null; then
  echo 'Could not set the archive ownership for transfer' >&2
  exit 1
fi
echo 'Collected files packed successfully'
REMOTE

mkdir -p "${ARTIFACT_DIR}"
# Keep the uncensored archive outside Prow's upload directory, even if interrupted.
transfer_archive=$(mktemp "${TMPDIR:-/tmp}/topology-gather.XXXXXX.tar.gz")
echo 'Copying the gathered archive to CI (20 minute limit)'
if timeout --kill-after=10s 20m scp "${SSHOPTS[@]}" "${remote}:${workdir}/gather.tar.gz" "${transfer_archive}" 2>/dev/null; then
  echo 'Gathered archive copied successfully'
else
  result=$?
  printf 'Could not copy the gathered archive (exit %s)\n' "${result}" >&2
  exit "${result}"
fi

# Keep the existing browsable artifact paths and let Prow censor files individually.
echo 'Unpacking gathered files into CI artifacts (5 minute limit)'
if ! timeout --kill-after=10s 5m tar -xzf "${transfer_archive}" -C "${ARTIFACT_DIR}" --no-same-owner --no-same-permissions 2>/dev/null; then
  echo 'Could not unpack the gathered archive' >&2
  exit 1
fi
echo 'Gathered files unpacked successfully'
