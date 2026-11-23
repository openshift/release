#!/bin/bash
set -euo pipefail

finish_step() {
  local result=$?

  trap - EXIT
  if (( result != 0 )); then
    printf 'Configure compact step: failed (exit %s)\n' "${result}" >&2
  else
    echo 'Configure compact step: completed successfully'
  fi

  exit "${result}"
}
trap finish_step EXIT

echo 'Configure compact step: starting'

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

ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" <<'REMOTE'
set -euo pipefail
cd "$1"
cleanup_remote() {
  local result=$?

  trap - EXIT
  if ! chown -R ec2-user:ec2-user .; then
    echo 'Could not restore host file ownership' >&2
    if (( result == 0 )); then
      result=1
    fi
  fi

  exit "${result}"
}
trap cleanup_remote EXIT

# shellcheck source=/dev/null
source common.sh

# Removing the SNO DNS MachineConfig can reboot nodes. Wait for all masters
# to be ready and healthy etcd voters before changing DNS.
expected_masters=$(jq -er '[.[] | select(.role == "control-plane")] | length | select(. > 0)' inventory.json)
sno_ip=$(jq -er '.[0].ip' inventory.json)
mkdir -p results
readiness_timeout=1200
started=${SECONDS}
attempt=0
while true; do
  attempt=$((attempt + 1))
  printf 'Pre-DNS readiness check: attempt %s, elapsed %ss of %ss\n' \
    "${attempt}" "$((SECONDS - started))" "${readiness_timeout}"

  if ready_nodes=$(oc --request-timeout=30s get nodes -l node-role.kubernetes.io/master -o json 2>/dev/null |
    jq -er --argjson count "${expected_masters}" '
      .items | select(length == $count and all(.[];
        .metadata.deletionTimestamp == null and
        any(.status.conditions[]?; .type == "Ready" and .status == "True"))) | .[].metadata.name' 2>/dev/null) &&
    pod=$(oc --request-timeout=30s -n openshift-etcd get pods -l app=etcd -o json 2>/dev/null | jq -er '
      [.items[] | select(.metadata.deletionTimestamp == null) |
        select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name][0] // empty' 2>/dev/null) &&
    timeout --kill-after=10s 45s oc --request-timeout=30s -n openshift-etcd exec "${pod}" -c etcdctl -- etcdctl member list -w json \
      > results/dns-etcd-members.json 2>/dev/null &&
    jq -e --argjson count "${expected_masters}" '.members | length == $count and
      all(.[]; .isLearner != true and .name != "")' results/dns-etcd-members.json >/dev/null 2>&1 &&
    timeout --kill-after=10s 45s oc --request-timeout=30s -n openshift-etcd exec "${pod}" -c etcdctl -- etcdctl endpoint health --cluster -w json \
      > results/dns-etcd-health.json 2>/dev/null &&
    jq -e --argjson count "${expected_masters}" 'length == $count and all(.[]; .health == true)' \
      results/dns-etcd-health.json >/dev/null 2>&1; then
    printf 'Pre-DNS checks passed with %s ready nodes and healthy etcd voters\n' "${expected_masters}"
    break
  fi
  if (( SECONDS - started >= readiness_timeout )); then
    echo 'Timed out waiting for ready control-plane nodes and healthy etcd voters before DNS cleanup' >&2
    exit 1
  fi

  echo 'Waiting for ready control-plane nodes and healthy etcd voters; retrying in 20s'
  sleep 20
done

check_guest_dns() {
  local phase=$1 nodes=$2 node checked_nodes failed_nodes attempt=0 started=${SECONDS}
  local dns_timeout=300

  while true; do
    attempt=$((attempt + 1))
    checked_nodes=0
    failed_nodes=0
    printf '%s-rollout guest DNS: attempt %s, elapsed %ss of %ss\n' \
      "${phase}" "${attempt}" "$((SECONDS - started))" "${dns_timeout}"

    while IFS= read -r node; do
      checked_nodes=$((checked_nodes + 1))
      printf 'Checking guest DNS on node %s of %s\n' "${checked_nodes}" "${expected_masters}"

      # -T keeps stdin attached when a command is given, so bash receives the checks.
      if ! timeout --kill-after=10s 60s oc --request-timeout=30s debug "node/${node}" --quiet -T -- chroot /host bash -s -- \
          "${gateway}" "${sno_ip}" "${cluster_domain}" "${phase}" >/dev/null 2>&1 <<'NODE_DNS'
set -euo pipefail
expected_ip=$1
old_ip=$2
domain=$3
phase=$4
override=/etc/default/sno_dnsmasq_configuration_overrides
override_value="SNO_DNSMASQ_IP_OVERRIDE=${expected_ip}"
dispatcher=/etc/NetworkManager/dispatcher.d/forcedns

if [[ "${phase}" == pre ]]; then
  # Use the Agent installer's override rather than editing a managed file.
  # The dispatcher must not restore the SNO resolver during the rollout.
  if [[ -x "${dispatcher}" ]]; then
    if [[ -e "${override}" || -L "${override}" ]]; then
      [[ -f "${override}" && ! -L "${override}" ]]
      [[ $(cat "${override}") == "${override_value}" ]]
    else
      printf '%s\n' "${override_value}" > "${override}"
    fi
    "${dispatcher}" '' up
    [[ $(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf) == "${expected_ip}" ]]
  fi
else
  [[ ! -e "${dispatcher}" ]]
  # The removed MachineConfig may have left a generated resolv.conf behind.
  # Let NetworkManager restore it if it still uses the SNO resolver.
  if awk -v old_ip="${old_ip}" '$1 == "nameserver" && $2 == old_ip { found = 1 } END { exit !found }' /etc/resolv.conf; then
    rm -f /etc/resolv.conf
    nmcli general reload
  fi
  service_state=$(systemctl show dnsmasq.service --property=ActiveState --value)
  [[ "${service_state}" == inactive || "${service_state}" == failed ]]
  if [[ -f "${override}" && $(cat "${override}") == "${override_value}" ]]; then
    rm -f "${override}"
  fi
fi

[[ -s /etc/resolv.conf ]]
awk -v old_ip="${old_ip}" '$1 == "nameserver" && $2 == old_ip { exit 1 }' /etc/resolv.conf

for name in "api.${domain}" "api-int.${domain}" "topology-dns-check.apps.${domain}" \
  "oauth-openshift.apps.${domain}" "console-openshift-console.apps.${domain}"; do
  answers=$(getent ahostsv4 "${name}" | awk '{print $1}' | sort -u)
  [[ "${answers}" == "${expected_ip}" ]]
done
NODE_DNS
      then
        failed_nodes=$((failed_nodes + 1))
      fi
    done <<< "${nodes}"

    if (( checked_nodes == expected_masters && failed_nodes == 0 )); then
      printf '%s-rollout guest DNS checks passed on all %s control-plane nodes\n' "${phase}" "${checked_nodes}"
      return
    fi
    if (( SECONDS - started >= dns_timeout )); then
      printf 'Timed out checking %s-rollout guest DNS; %s of %s nodes failed the last check\n' \
        "${phase}" "${failed_nodes}" "${checked_nodes}" >&2
      return 1
    fi

    printf 'Guest DNS pending on %s of %s nodes; retrying in 10s\n' "${failed_nodes}" "${checked_nodes}"
    sleep 10
  done
}

# As in TNT, move API DNS to HAProxy after the new control-plane nodes join.
echo 'Moving API DNS to the load balancer'
set_api_dns "${gateway}"

# Switch the node resolvers before the MachineConfig can reboot the SNO node.
check_guest_dns pre "${ready_nodes}"

echo 'Removing the SNO DNS MachineConfig'
for attempt in 1 2 3 4 5; do
  printf 'SNO DNS config removal: attempt %s of 5\n' "${attempt}"
  if oc --request-timeout=30s delete machineconfig 50-master-dnsmasq-configuration --ignore-not-found=true --wait=false >/dev/null 2>&1; then
    break
  fi
  if (( attempt == 5 )); then
    echo 'Could not remove the SNO DNS MachineConfig' >&2
    exit 1
  fi

  echo 'SNO DNS config removal pending; retrying in 5s'
  sleep 5
done

rollout_timeout=1800
started=${SECONDS}
attempt=0
while true; do
  attempt=$((attempt + 1))
  printf 'DNS rollout check: attempt %s, elapsed %ss of %ss\n' \
    "${attempt}" "$((SECONDS - started))" "${rollout_timeout}"

  # Updated=True may still describe the old config just after deletion. Both
  # source lists must drop the SNO config before an otherwise healthy pool passes.
  if oc --request-timeout=30s get machineconfigpool master -o json > results/dns-master-pool.json 2>/dev/null &&
    jq -e --argjson count "${expected_masters}" '
      .spec.paused != true and
      .status.observedGeneration == .metadata.generation and
      .spec.configuration.name == .status.configuration.name and
      all((.spec.configuration.source + .status.configuration.source)[];
        .name != "50-master-dnsmasq-configuration") and
      .status.machineCount == $count and
      .status.updatedMachineCount == $count and
      .status.readyMachineCount == $count and
      .status.unavailableMachineCount == 0 and
      any(.status.conditions[]; .type == "Updated" and .status == "True") and
      any(.status.conditions[]; .type == "Updating" and .status == "False") and
      any(.status.conditions[]; .type == "Degraded" and .status == "False")
      ' results/dns-master-pool.json >/dev/null 2>&1 &&
    oc --request-timeout=30s get nodes -l node-role.kubernetes.io/master -o json > results/dns-master-nodes.json 2>/dev/null &&
    jq -e --argjson count "${expected_masters}" --slurpfile pool results/dns-master-pool.json '
      .items | length == $count and all(.[];
        .metadata.annotations["machineconfiguration.openshift.io/currentConfig"] == $pool[0].spec.configuration.name and
        .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] == $pool[0].spec.configuration.name and
        .metadata.annotations["machineconfiguration.openshift.io/state"] == "Done" and
        any(.status.conditions[]; .type == "Ready" and .status == "True"))
      ' results/dns-master-nodes.json >/dev/null 2>&1; then
    echo 'DNS MachineConfig rollout completed on all control-plane nodes'
    break
  fi
  if (( SECONDS - started >= rollout_timeout )); then
    echo 'Timed out waiting for the DNS MachineConfig rollout' >&2
    exit 1
  fi

  echo 'Waiting for the DNS config to be removed and all nodes to recover; retrying in 20s'
  sleep 20
done

rolled_out_nodes=$(jq -er '.items[].metadata.name' results/dns-master-nodes.json)
check_guest_dns post "${rolled_out_nodes}"

# Existing DNS pod sandboxes may still have the old node resolv.conf. Recreate
# them after host repair so both the upstream resolver and cached answers refresh.
echo 'Refreshing cluster DNS pods after node DNS cleanup'
if ! oc --request-timeout=30s -n openshift-dns rollout restart daemonset/dns-default >/dev/null 2>&1; then
  echo 'Could not refresh cluster DNS pods' >&2
  exit 1
fi
if ! timeout --kill-after=10s 330s oc --request-timeout=30s -n openshift-dns rollout status daemonset/dns-default --timeout=5m >/dev/null 2>&1; then
  echo 'Cluster DNS pods did not finish rolling out' >&2
  exit 1
fi
echo 'Cluster DNS pods refreshed successfully'

# Compact-cluster scheduling policy belongs to this workflow, not add-nodes.
echo 'Enabling worker scheduling on control-plane nodes'
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'
oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker= --overwrite >/dev/null
oc adm uncordon -l node-role.kubernetes.io/master >/dev/null

REMOTE
