#!/usr/bin/env bash
set -euo pipefail
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
export FIXTURE_ROOT=${temporary}
original_path=${PATH}
agent=${repository}/ci-operator/step-registry/agent/gather/agent-gather-commands.sh
fallback=${repository}/ci-operator/step-registry/baremetalds/devscripts/gather/baremetalds-devscripts-gather-commands.sh
cases=0

prepare() {
  rm -rf "${temporary:?}"/*
  mkdir -p "${temporary}"/{bin,shared,artifacts,remote/dev-scripts/{agent,logs,ocp/ostest},remote/tmp/artifacts}
  for command_name in timeout ssh scp make oc sos podman sudo virsh xmllint tar; do
    ln -s "${repository}/hack/testdata/agent-tnf-gather/command.sh" "${temporary}/bin/${command_name}"
  done
  export PATH=${temporary}/bin:${original_path} SHARED_DIR=${temporary}/shared ARTIFACT_DIR=${temporary}/artifacts NAMESPACE=fixture
  export DEVSCRIPTS_GATHER_AGENT=true
  unset REMOTE_RC MAKE_RC SCP_RC COLLECTOR_RC UNREACHABLE REAL_TIMEOUT MAKE_SLEEP COLLECTION_SLEEP HANG_AGENT_PATTERN NODE_LOGS
  printf 'IP=203.0.113.1\nSSHOPTS=()\n' > "${SHARED_DIR}/packet-conf.sh"
  touch "${SHARED_DIR}/server-ip" "${SHARED_DIR}/devscripts-logs-collected"
  cat > "${temporary}/remote/dev-scripts/common.sh" <<'EOF'
OCP_DIR=ocp/ostest
NUM_MASTERS=2
NUM_WORKERS=0
NUM_EXTRA_WORKERS=0
MASTER_HOSTNAME_FORMAT=master-%d
WORKER_HOSTNAME_FORMAT=worker-%d
BOOTSTRAP_PROVISIONING_IP=192.168.111.2
BAREMETAL_NETWORK_NAME=ostestbm
NODE_IPS=()
shopt -s nocasematch
set -x
EOF
  printf 'wrap_if_ipv6() { if [[ "$1" == *:* ]]; then printf "[%%s]" "$1"; else printf "%%s" "$1"; fi; }\n' > "${temporary}/remote/dev-scripts/network.sh"
  touch "${temporary}/remote/dev-scripts/"{config_root.sh,utils.sh,ocp_install_env.sh}
  printf 'set -o pipefail\n' > "${temporary}/remote/dev-scripts/utils.sh"
  printf 'set -euxo pipefail\ngetRendezvousIP() { cat "$FIXTURE_ROOT/rendezvous"; }\n' > "${temporary}/remote/dev-scripts/agent/common.sh"
  printf '192.168.111.80 master-0\n192.168.111.81 master-1\n' > "${temporary}/remote/dev-scripts/ocp/ostest/hosts"
  echo 192.168.111.80 > "${temporary}/rendezvous"
  echo 1 > "${temporary}/remote/dev-scripts/logs/installer-status.txt"
  echo diagnostic > "${temporary}/log"
  /usr/bin/tar -cJf "${temporary}/remote/dev-scripts/agent-gather-master-0.tar.xz" -C "${temporary}" log
  /usr/bin/tar -cf "${temporary}/remote/dev-scripts/ocp/ostest/installation-logs.tar" -C "${temporary}" log
  /usr/bin/tar -czf "${temporary}/remote/tmp/artifacts/partial.tar.gz" -C "${temporary}" log
}

run_step() {
  local expected=$2 status=0
  bash "$1" > "${temporary}/output" 2>&1 || status=$?
  if [[ "${status}" != "${expected}" ]]; then cat "${temporary}/output"; echo "Expected ${expected}, got ${status}"; exit 1; fi
  cases=$((cases + 1))
}

for identifier in hostname macAddress; do
  prepare
  export FENCING_CREDENTIAL_IDENTIFIER=${identifier}
  run_step "${fallback}" 0
  grep -q 'core@192.168.111.80' "${temporary}/calls"
  grep -q 'core@192.168.111.81' "${temporary}/calls"
  ! grep -Eq 'net-dumpxml|core@192.168.111.(2|20|21) ' "${temporary}/calls"
  grep -q 'Agent rendezvous selected' "${temporary}/output"
done
for scenario in hostname macAddress unreachable; do
  prepare
  unreachable=none
  if [[ "${scenario}" == unreachable ]]; then unreachable=192.168.111.80; else export FENCING_CREDENTIAL_IDENTIFIER=${scenario}; fi
  export NODE_LOGS=true UNREACHABLE=${unreachable}
  rm "${temporary}/remote/tmp/artifacts/partial.tar.gz"
  run_step "${fallback}" 0
  for node in 0 1; do
    address=192.168.111.$((80 + node))
    if [[ "${address}" == "${unreachable}" ]]; then
      test ! -f "${ARTIFACT_DIR}/journal_${address}.tar.gz"
      test ! -f "${ARTIFACT_DIR}/pacemaker_master-${node}.tar.gz"
      continue
    fi
    grep -Fq "core@${address} sudo cat /var/log/pacemaker/pacemaker.log" "${temporary}/calls"
    grep -Fq "core@${address} sudo podman logs etcd" "${temporary}/calls"
    grep -Fq "core@${address} sudo journalctl | sudo dd of=/var/log/journal.log" "${temporary}/calls"
    grep -Fq "core@${address} sudo tar -czf /run/artifacts/journal_${address}.tar.gz" "${temporary}/calls"
    grep -Eq "^scp .*core@${address}:/run/artifacts/\\*.tar" "${temporary}/calls"
    pacemaker=$(/usr/bin/tar -xOzf "${ARTIFACT_DIR}/pacemaker_master-${node}.tar.gz" "pacemaker_master-${node}.log")
    [[ "${pacemaker}" == *"synthetic pacemaker core@${address}"* ]]
    [[ "${pacemaker}" == *'name="password" value="REDACTED" name="passwd" value="REDACTED" name="username" value="REDACTED"'* ]]
    [[ "${pacemaker}" != *fixture-* ]]
    /usr/bin/tar -xOzf "${ARTIFACT_DIR}/podman-etcd_master-${node}.tar.gz" "podman-etcd_master-${node}.log" | grep -Fq "synthetic etcd core@${address}"
    /usr/bin/tar -xOzf "${ARTIFACT_DIR}/journal_${address}.tar.gz" journal.log | grep -Fq "synthetic journal core@${address}"
  done
  ! grep -Eq 'net-dumpxml|core@192.168.111.(2|20|21) ' "${temporary}/calls"
done
prepare
unset DEVSCRIPTS_GATHER_AGENT
run_step "${fallback}" 0
grep -q net-dumpxml "${temporary}/calls"
grep -q 'core@192.168.111.20' "${temporary}/calls"
grep -q 'core@192.168.111.2 ' "${temporary}/calls"
for missing in empty absent; do
  prepare
  if [[ "${missing}" == empty ]]; then : > "${temporary}/remote/dev-scripts/ocp/ostest/hosts"; else rm "${temporary}/remote/dev-scripts/ocp/ostest/hosts"; fi
  run_step "${fallback}" 0
  grep -q 'Agent inventory unavailable' "${temporary}/output"
  ! grep -q 'core@' "${temporary}/calls"
  test -f "${ARTIFACT_DIR}/partial.tar.gz"
done
for metadata in missing unlisted; do
  prepare
  if [[ "${metadata}" == missing ]]; then rm "${temporary}/remote/dev-scripts/agent/common.sh"; else echo 192.168.111.99 > "${temporary}/rendezvous"; fi
  run_step "${fallback}" 0
  grep -q 'Agent rendezvous unavailable' "${temporary}/output"
  ! grep -q 'core@192.168.111.2 ' "${temporary}/calls"
done
for availability in 127 255; do
  prepare
  if [[ "${availability}" == 127 ]]; then export COLLECTOR_RC=127; else export UNREACHABLE=192.168.111.80; fi
  run_step "${fallback}" 0
  grep -q "master-0 192.168.111.80 rc=${availability}" "${temporary}/output"
  grep -q 'core@192.168.111.81' "${temporary}/calls"
done
for status in 2 124 137 255; do
  prepare
  export REMOTE_RC=${status}
  run_step "${agent}" "${status}"
  test -f "${ARTIFACT_DIR}/agent-gather-master-0.tar.xz"
  test -f "${ARTIFACT_DIR}/installation-logs.tar"
  cmp "${ARTIFACT_DIR}/agent-gather-master-0.tar.xz" "${temporary}/remote/dev-scripts/agent-gather-master-0.tar.xz"
  cmp "${ARTIFACT_DIR}/installation-logs.tar" "${temporary}/remote/dev-scripts/ocp/ostest/installation-logs.tar"
  run_step "${fallback}" "${status}"
  test -f "${ARTIFACT_DIR}/partial.tar.gz"
done
prepare
rm "${temporary}/remote/dev-scripts/config_root.sh"
run_step "${fallback}" 0
grep -q 'dev-scripts configuration missing' "${temporary}/output"
test -f "${ARTIFACT_DIR}/partial.tar.gz"
prepare
rm "${SHARED_DIR}/devscripts-logs-collected"
printf 'password: synthetic-private\n' > "${temporary}/remote/dev-scripts/logs/setup.log"
run_step "${fallback}" 0
test -f "${ARTIFACT_DIR}/root/dev-scripts/logs/setup.log" || test -f "${ARTIFACT_DIR}/dev-scripts/logs/setup.log"
! grep -R 'synthetic-private' "${ARTIFACT_DIR}"
for absent in agent installation; do
  prepare
  if [[ "${absent}" == agent ]]; then rm "${temporary}/remote/dev-scripts/agent-gather-master-0.tar.xz"; else rm "${temporary}/remote/dev-scripts/ocp/ostest/installation-logs.tar"; fi
  run_step "${agent}" 0
  if [[ "${absent}" == agent ]]; then test -f "${ARTIFACT_DIR}/installation-logs.tar"; else test -f "${ARTIFACT_DIR}/agent-gather-master-0.tar.xz"; fi
done
prepare
export MAKE_RC=23 SCP_RC=255
run_step "${agent}" 23
prepare
export REMOTE_RC=23 SCP_RC=255
run_step "${fallback}" 23
prepare
export REAL_TIMEOUT=true
export COLLECTION_SLEEP=true
run_step "${fallback}" 124
test -f "${ARTIFACT_DIR}/partial.tar.gz"
grep -q 'timeout -s 9 10m ssh' "${temporary}/calls"
grep -q 'timeout --kill-after=5s 45s scp' "${temporary}/calls"
prepare
export REAL_TIMEOUT=true MAKE_SLEEP=true
run_step "${agent}" 124
test -f "${ARTIFACT_DIR}/agent-gather-master-0.tar.xz"
test -f "${ARTIFACT_DIR}/installation-logs.tar"
prepare
export REAL_TIMEOUT=true HANG_AGENT_PATTERN=true
run_step "${agent}" 0
grep -q 'agent-gather\*.tar.xz, rc=124' "${temporary}/output"
test -f "${ARTIFACT_DIR}/installation-logs.tar"
prepare
printf 'getRendezvousIP() { echo 192.168.111.80; }; return 7\n' > "${temporary}/remote/dev-scripts/agent/common.sh"
run_step "${fallback}" 0
grep -q 'Agent rendezvous unavailable' "${temporary}/output"
grep -q 'core@192.168.111.81' "${temporary}/calls"
echo "PASS: ${cases} real command-script cases (mocked transports; no live installation/readability proof)"
