#!/bin/bash
set -euo pipefail

if [[ ! "${NODE_INVENTORY}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ ]]; then
  echo 'NODE_INVENTORY must name an inventory file on the EC2 host' >&2
  exit 1
fi
for count in "${EXPECTED_NODES}" "${ETCD_VOTING_MEMBERS}"; do
  if [[ -n "${count}" && ! "${count}" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Optional node and etcd counts must be positive integers' >&2
    exit 1
  fi
done
case "${CONTROL_PLANE_AS_WORKERS}" in
  true|false) ;;
  *) echo 'CONTROL_PLANE_AS_WORKERS must be true or false' >&2; exit 1 ;;
esac

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
printf -v remote_args '%q ' "${workdir}" "${NODE_INVENTORY}" "${EXPECTED_NODES}" \
  "${ETCD_VOTING_MEMBERS}" "${CONTROL_PLANE_AS_WORKERS}"

ssh "${SSHOPTS[@]}" "${remote}" "sudo bash -s -- ${remote_args}" <<'REMOTE'
set -euo pipefail
cd "$1"
trap 'chown -R ec2-user:ec2-user .' EXIT
inventory=$2
expected_nodes=$3
etcd_members=$4
control_plane_as_workers=$5
# shellcheck source=/dev/null
source common.sh

# Fail on an invalid handoff instead of passing an empty batch.
jq -e 'type == "array" and length > 0 and
  all(.[]; (.name | type == "string" and length > 0) and
    (.role == "control-plane" or .role == "worker" or .role == "infra")) and
  ([.[].name] | length == (unique | length))' "${inventory}" >/dev/null

deadline=$((SECONDS + 3600))
while (( SECONDS < deadline )); do
  if ! oc --request-timeout=30s get nodes -o json > results/scaling-nodes.json || \
    ! jq -e --slurpfile expected "${inventory}" --arg count "${expected_nodes}" \
      --argjson compact "${control_plane_as_workers}" '
      .items as $nodes |
      (if $count == "" then true else ($nodes | length) == ($count | tonumber) end) and
      all($expected[0][]; . as $node | any($nodes[];
        .metadata.name == $node.name and
        (.metadata.labels | has("node-role.kubernetes.io/" +
          (if $node.role == "control-plane" then "master" else $node.role end))) and
        (.spec.unschedulable != true) and
        any(.status.conditions[]; .type == "Ready" and .status == "True") and
        (if $compact and $node.role == "control-plane" then
          (.metadata.labels | has("node-role.kubernetes.io/worker")) and
          all(.spec.taints[]?; .effect != "NoSchedule" and .effect != "NoExecute")
        else true end)))' results/scaling-nodes.json >/dev/null; then
    sleep 20
    continue
  fi

  # Workers and infra nodes need no etcd membership check by default.
  if [[ -z "${etcd_members}" ]]; then
    exit 0
  fi
  if ! pod=$(oc --request-timeout=30s -n openshift-etcd get pods -l app=etcd -o json | jq -r '
    [.items[] | select(.metadata.deletionTimestamp == null) |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name][0] // empty'); then
    sleep 20
    continue
  fi
  if [[ -n "${pod}" ]] && \
    oc --request-timeout=30s -n openshift-etcd exec "${pod}" -c etcdctl -- etcdctl member list -w json > results/etcd-members.json && \
    jq -e --argjson count "${etcd_members}" '.members | length == $count and
      all(.[]; .isLearner != true and .name != "")' results/etcd-members.json >/dev/null && \
    oc --request-timeout=30s -n openshift-etcd exec "${pod}" -c etcdctl -- etcdctl endpoint health --cluster -w json > results/etcd-health.json && \
    jq -e --argjson count "${etcd_members}" 'length == $count and all(.[]; .health == true)' results/etcd-health.json >/dev/null; then
    exit 0
  fi
  sleep 20
done

echo 'Timed out waiting for the expected nodes, roles, or configured etcd target' >&2
exit 1
REMOTE
