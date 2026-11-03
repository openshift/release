#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'result=$?; if ((result != 0)); then cat "$fixture/"*.log >&2; fi; rm -rf "$fixture"' EXIT
export FIXTURE="$fixture"
mkdir -p "$fixture"/{bin,root/dev-scripts/ocp/ostest,root/dev-scripts/logs,tmp/artifacts,shared,artifacts}
export SHARED_DIR="$fixture/shared" ARTIFACT_DIR="$fixture/artifacts" NAMESPACE=fixture
export CALLS="$fixture/calls"
printf 'IP=fixture\nSSHOPTS=()\n' > "$SHARED_DIR/packet-conf.sh"
touch "$SHARED_DIR/server-ip" "$SHARED_DIR/devscripts-logs-collected"
echo 1 > "$SHARED_DIR/install-status.txt"
echo 0 > "$fixture/root/dev-scripts/logs/installer-status.txt"
echo diagnostic > "$fixture/tmp/artifacts/fixture.tar.gz"
cat > "$fixture/root/dev-scripts/common.sh" <<'COMMON'
NUM_MASTERS=2
NUM_WORKERS=0
NUM_EXTRA_WORKERS=0
MASTER_HOSTNAME_FORMAT=${MASTER_FORMAT:-master-%d}
WORKER_HOSTNAME_FORMAT=worker-%d
BAREMETAL_NETWORK_NAME=fixture
BOOTSTRAP_PROVISIONING_IP=172.22.0.2
OCP_DIR=ocp/ostest
NODE_IPS=()
AGENT_E2E_TEST_SCENARIO=${AGENT_SCENARIO:-}
wrap_if_ipv6() { printf '%s\n' "$1"; }
openshift_version() { echo 5.0; }
COMMON
touch "$fixture/root/dev-scripts/"{network,utils,ocp_install_env}.sh
cat > "$fixture/bin/ssh" <<'SSH'
#!/bin/bash
set -eu
printf 'ssh %s\n' "$*" >> "$CALLS"
no_stdin=false
while [[ "$1" == -o || "$1" == -n ]]; do
    if [[ "$1" == -n ]]; then no_stdin=true; shift; else shift 2; fi
done
destination=$1
shift
if [[ "$destination" == core@* ]]; then
    if [[ "${CASE:-}" == stdin-drain && "$no_stdin" == false ]]; then cat >/dev/null; fi
    if [[ "${CASE:-}" == unreachable && "$destination" == core@192.168.111.80 ]]; then exit 255; fi
    if [[ "$*" == *podman*ps* ]]; then
        if [[ "${CASE:-}" == probe-error ]]; then exit 125; fi
        if [[ "${CASE:-}" != absent ]]; then echo etcd; fi
    elif [[ "$*" == *"test -f"* ]]; then
        if [[ "${CASE:-}" == probe-error ]]; then exit 1; fi
        if [[ "${CASE:-}" == absent ]]; then echo file_absent; else echo present; fi
    elif [[ "$*" == *pacemaker.log* ]]; then
        echo '<nvpair name="password" value="SYNTHETIC_SECRET"/>'
        echo 'pacemaker fixture'
    else echo 'guest fixture'; fi
    exit
fi
if [[ "$*" == 'bash -' ]]; then
    [[ "$no_stdin" == false ]] || exit 0
    cd "$FIXTURE/root"
    sed "s@/root/dev-scripts@FIXTURE_ROOT@g; s@/tmp/@FIXTURE_TMP/@g; s@/tmp @FIXTURE_TMP @g; s@\"/tmp\"@\"FIXTURE_TMP\"@g; s@/var/log/@FIXTURE_LOG/@g; s@FIXTURE_ROOT@$FIXTURE/root/dev-scripts@g; s@FIXTURE_TMP@$FIXTURE/tmp@g; s@FIXTURE_LOG@$FIXTURE/var/log@g" | bash
else exit 99; fi
SSH
cat > "$fixture/bin/scp" <<'SCP'
#!/bin/bash
set -eu
echo "scp $*" >> "$CALLS"
if [[ ( "${HANG_TRANSFER:-}" == agent || "${HANG_TRANSFER:-}" == both ) && "$*" == *agent-gather* ]] ||
   [[ ( "${HANG_TRANSFER:-}" == optional || "${HANG_TRANSFER:-}" == both ) && "$*" == *installation-logs.tar* ]]; then
    trap '' TERM
    sleep 2
fi
case "$*" in
*agent-gather*|*installation-logs.tar*)
    source=${1#*:}
    source=${source/\/root\/dev-scripts/$FIXTURE/root/dev-scripts}
    mapfile -t matches < <(compgen -G "$source")
    ((${#matches[@]} > 0)) || exit 1
    cp "${matches[@]}" "$ARTIFACT_DIR/"
    ;;
*'/tmp/artifacts/'*) cp "$FIXTURE/tmp/artifacts/"*.tar* "$ARTIFACT_DIR/" ;;
*) exit 1 ;;
esac
SCP
cat > "$fixture/bin/timeout" <<'TIMEOUT'
#!/bin/bash
set -eu
printf 'timeout %s\n' "$*" >> "$CALLS"
if [[ "$1" == -s ]]; then shift 3; else shift 2; fi
if [[ "$1" == scp ]]; then exec /usr/bin/timeout --kill-after=0.05 0.05 "$@"; fi
exec "$@"
TIMEOUT
cat > "$fixture/bin/sudo" <<'SUDO'
#!/bin/bash
set -eu
echo "sudo $*" >> "$CALLS"
if [[ "$*" == *virsh* ]]; then echo fixture-xml; else exit 99; fi
SUDO
cat > "$fixture/bin/xmllint" <<'XML'
#!/bin/bash
cat >/dev/null
if [[ "$*" == *master-0* ]]; then echo 192.168.111.20; else echo 192.168.111.21; fi
XML
for command in sos podman oc; do
    printf '#!/bin/bash\nexit 1\n' > "$fixture/bin/$command"
done
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
generic="$repo/ci-operator/step-registry/baremetalds/devscripts/gather/baremetalds-devscripts-gather-commands.sh"
agent="$repo/ci-operator/step-registry/agent/gather/agent-gather-commands.sh"
export AGENT_SCENARIO=TNF_IPV4
for scenario in static unreachable probe-error absent missing conflict ipv6 malformed extra repeated missing-first non-agent; do
    export CASE=$scenario
    : > "$CALLS"
    printf '192.168.111.80 master-0\n192.168.111.81 master-1\n' > "$fixture/root/dev-scripts/ocp/ostest/hosts"
    case "$scenario" in
        missing) : > "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        conflict) echo '192.168.111.20 master-0' >> "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        ipv6) printf 'fd00::80 master-0\nfd00::81 master-1\n' > "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        malformed) printf 'abc master-0\n192.168.111.81 master-1\n' > "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        extra) echo '192.168.111.80 master-0 extra' >> "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        repeated) echo '192.168.111.80 master-0' >> "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        missing-first) echo '192.168.111.81 master-1' > "$fixture/root/dev-scripts/ocp/ostest/hosts" ;;
        non-agent) export AGENT_SCENARIO= ;;
    esac
    bash "$generic" > "$fixture/$scenario.log" 2>&1
    case "$scenario" in
        non-agent) grep -q core@192.168.111.20 "$CALLS"; grep -q 'sudo virsh' "$CALLS" ;;
        missing) if grep -q 'core@192.168.111' "$CALLS"; then exit 1; fi; grep -q address=unknown "$fixture/$scenario.log" ;;
        conflict|malformed|extra|missing-first) if grep -q 'core@192.168.111.80' "$CALLS"; then exit 1; fi; grep -q 'core@192.168.111.81' "$CALLS" ;;
        ipv6) grep -q core@fd00::80 "$CALLS" ;;
        *)
            grep -q core@192.168.111.80 "$CALLS"
            if grep -q core@192.168.111.20 "$CALLS"; then exit 1; fi
            if grep -q 'sudo virsh' "$CALLS"; then exit 1; fi
            ;;
    esac
    if [[ "$scenario" == unreachable || "$scenario" == probe-error ]]; then
        grep -q pacemaker_log=unknown "$fixture/$scenario.log"
        grep -q podman_etcd=unknown "$fixture/$scenario.log"
    elif [[ "$scenario" == absent ]]; then
        grep -q pacemaker_log=file_absent "$fixture/$scenario.log"
        grep -q podman_etcd=container_absent "$fixture/$scenario.log"
    fi
    if [[ "$scenario" == static ]]; then
        tar -xOf "$ARTIFACT_DIR/pacemaker_master-0.tar.gz" | grep -q REDACTED
        if tar -xOf "$ARTIFACT_DIR/pacemaker_master-0.tar.gz" | grep -q SYNTHETIC_SECRET; then exit 1; fi
    fi
    echo "PASS generic $scenario"
done

review_failures=0
export AGENT_SCENARIO=TNF_IPV4
printf '192.168.111.80 master-0\n192.168.111.81 master-1\n' > "$fixture/root/dev-scripts/ocp/ostest/hosts"
export CASE=stdin-drain
echo 1 > "$fixture/root/dev-scripts/logs/installer-status.txt"
: > "$CALLS"
bash "$generic" > "$fixture/stdin-drain.log" 2>&1
if grep -q 'host=master-1 podman_etcd=present' "$fixture/stdin-drain.log" &&
   [[ $(grep -c 'sudo chown' "$CALLS") == 2 ]]; then
    echo 'PASS nested SSH preserves script stdin through probes and SOS'
else
    echo 'FAIL nested SSH consumed script stdin' >&2
    review_failures=$((review_failures + 1))
fi
echo 0 > "$fixture/root/dev-scripts/logs/installer-status.txt"
export CASE=redact-names MASTER_FORMAT=PRIVATE_NODE_%d
printf 'abc PRIVATE_NODE_0\n192.168.111.81 PRIVATE_NODE_1\n' > "$fixture/root/dev-scripts/ocp/ostest/hosts"
bash "$generic" > "$fixture/redact-names.log" 2>&1
if ! grep -q PRIVATE_NODE "$fixture/redact-names.log" &&
   grep -q 'node_index=0 address=unknown' "$fixture/redact-names.log" &&
   grep -q 'host=master-1 podman_etcd=present' "$fixture/redact-names.log"; then
    echo 'PASS diagnostic identifiers use stable indices'
else
    echo 'FAIL diagnostic identifiers expose raw node names' >&2
    review_failures=$((review_failures + 1))
fi
unset MASTER_FORMAT

cat > "$fixture/bin/make" <<'MAKE'
#!/bin/bash
if [[ "${DROP_ARCHIVE:-0}" == 0 ]]; then
    tar -cJf "$FIXTURE/root/dev-scripts/agent-gather-fallback-master-0.tar.xz" -C "$FIXTURE/root/dev-scripts/logs" installer-status.txt
fi
exit "${MAKE_STATUS:-0}"
MAKE
chmod +x "$fixture/bin/make"
for combination in 0:0 2:0 124:0 0:1 2:1; do
    status=${combination%:*}
    export DROP_ARCHIVE=${combination#*:}
    rm -f "$fixture/root/dev-scripts/agent-gather-fallback-master-0.tar.xz"
    export ARTIFACT_DIR="$fixture/publication-$combination"
    mkdir "$ARTIFACT_DIR"
    export MAKE_STATUS=$status
    result=0
    bash "$agent" > "$fixture/agent-$status.log" 2>&1 || result=$?
    expected=$status
    if [[ "$status" == 0 && "$DROP_ARCHIVE" == 1 ]]; then expected=1; fi
    [[ "$result" == "$expected" ]]
    if [[ "$DROP_ARCHIVE" == 0 ]]; then
        tar -tJf "$ARTIFACT_DIR/agent-gather-fallback-master-0.tar.xz" | grep -q installer-status.txt
    elif [[ -e "$ARTIFACT_DIR/agent-gather-fallback-master-0.tar.xz" ]]; then exit 1; fi
    grep -q 'Optional installation logs unavailable' "$fixture/agent-$status.log"
    echo "PASS agent publication collection=$status missing_archive=$DROP_ARCHIVE"
done

mkdir -p "$fixture/root/dev-scripts/ocp/ostest"
tar -cf "$fixture/root/dev-scripts/ocp/ostest/installation-logs.tar" -C "$fixture/root/dev-scripts/logs" installer-status.txt
for transfer in agent optional both; do
    export HANG_TRANSFER=$transfer DROP_ARCHIVE=0 MAKE_STATUS=0
    [[ "$transfer" != both ]] || export MAKE_STATUS=124
    export ARTIFACT_DIR="$fixture/transfer-$transfer"
    mkdir "$ARTIFACT_DIR"
    : > "$CALLS"
    result=0
    /usr/bin/timeout --kill-after=0.1 1 bash "$agent" > "$fixture/transfer-$transfer.log" 2>&1 || result=$?
    expected=0
    [[ "$transfer" != agent ]] || expected=137
    [[ "$transfer" != both ]] || expected=124
    if [[ "$result" == "$expected" ]] &&
       grep -q 'Agent collection exit' "$fixture/transfer-$transfer.log" &&
       grep -q installation-logs.tar "$CALLS" &&
       grep -q 'timeout -s 9 15m ssh' "$CALLS" &&
       [[ $(grep -c 'timeout --kill-after=5s 5m scp' "$CALLS") == 2 ]]; then
        if [[ "$transfer" == agent ]]; then
            test -f "$ARTIFACT_DIR/installation-logs.tar"
        elif [[ "$transfer" == optional ]]; then
            tar -tJf "$ARTIFACT_DIR/agent-gather-fallback-master-0.tar.xz" | grep -q installer-status.txt
            grep -q 'Optional installation logs unavailable (exit 137)' "$fixture/transfer-$transfer.log"
        fi
        echo "PASS bounded transfer $transfer with independent publication/status"
    else
        echo "FAIL unbounded transfer $transfer" >&2
        review_failures=$((review_failures + 1))
    fi
done
unset HANG_TRANSFER

python3 - "$repo" <<'PYTHON'
from pathlib import Path
import sys
import yaml

repo = Path(sys.argv[1])
registry = repo / 'ci-operator/step-registry'

def definition(name, kind):
    matches = list(registry.glob(f'**/{name}-{kind}.yaml'))
    assert len(matches) == 1, (name, matches)
    return yaml.safe_load(matches[0].read_text())[kind]

def flatten(steps):
    result = []
    for step in steps:
        if 'chain' in step:
            result.extend(flatten(definition(step['chain'], 'chain')['steps']))
        elif 'ref' in step:
            result.append(step['ref'])
    return result

for version in ('5.0', '5.1'):
    config = yaml.safe_load((repo / f'ci-operator/config/openshift/release/openshift-release-main__nightly-{version}.yaml').read_text())
    assert config['base_images']['dev-scripts'] == dict(name='test', namespace='ocp-kni', tag='dev-scripts')
    assert config['zz_generated_metadata']['branch'] == 'main'
    for name in ('e2e-agent-ovn-two-node-fencing', 'e2e-agent-ovn-two-node-fencing-mac'):
        test = next(test for test in config['tests'] if test['as'] == name)
        steps = definition(test['steps']['workflow'], 'workflow')['steps']
        assert steps['env']['DEVSCRIPTS_TARGET'] == 'agent'
        assert 'baremetalds-devscripts-setup' in flatten(steps['pre'])
        post = flatten(steps['post'])
        assert post.index('agent-gather') < post.index('baremetalds-devscripts-gather')
        for ref in ('baremetalds-devscripts-setup', 'agent-gather', 'baremetalds-devscripts-gather'):
            assert definition(ref, 'ref')['from'] == 'dev-scripts'
        print(f'PASS consumer {version} {name}')
PYTHON
((review_failures == 0))
