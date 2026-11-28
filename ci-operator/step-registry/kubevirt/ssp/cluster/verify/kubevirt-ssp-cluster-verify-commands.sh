#!/bin/bash
# shellcheck disable=SC2016 # $expected inside jq is supplied by --slurpfile.
set +x
set -euo pipefail
umask 077

fail() { echo "$1" >&2; exit 1; }
: "${SHARED_DIR:?}" "${ARTIFACT_DIR:?}"
# 1. Use the kubeconfig downloaded by provision, plus its expected identity.
# All oc calls below now contact the target cluster, not the build-farm cluster.
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
expected="${SHARED_DIR}/cluster-api-expected.json"
[[ -s $KUBECONFIG && -s $expected ]] || fail "Provisioning handoff is missing"
budget=${CLUSTER_API_VERIFY_SECONDS:-900}
if [[ ! $budget =~ ^[1-9][0-9]*$ ]] || (( budget > 900 )); then
  fail "Invalid verification budget"
fi
tmp=$(mktemp -d)
started=$SECONDS
outcome=failed
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local result=$?
  trap - EXIT
  rm -rf "$tmp"
  jq -n --arg outcome "$outcome" --argjson seconds "$((SECONDS - started))" \
    '{outcome:$outcome,elapsed_seconds:$seconds}' > "${ARTIFACT_DIR}/cluster-verification.json" || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Readiness failures are retryable. Remember a fixed, non-sensitive explanation
# for the deadline message; never include node names or raw API responses.
reason="Cluster API is not reachable"
check_ready() {
  local file=$1 message=$2 filter=$3
  shift 3
  if ! jq -e "$@" "$filter" "$tmp/$file" >/dev/null 2>&1; then
    reason=$message
    return 1
  fi
}

release_ready() {
  check_ready version "OpenShift version does not match" \
    '.status.desired.version == $expected[0].openshift_version' --slurpfile expected "$expected" || return 1
  check_ready version "OpenShift release image does not match" \
    '.status.desired.image == $expected[0].release_image' --slurpfile expected "$expected" || return 1
  check_ready version "OpenShift installation has not completed" '.status.history[0].state == "Completed"' || return 1
  check_ready version "OpenShift is not available" 'any(.status.conditions[]?; .type == "Available" and .status == "True")' || return 1
  check_ready version "OpenShift is still progressing" 'any(.status.conditions[]?; .type == "Progressing" and .status == "False")' || return 1
  check_ready version "OpenShift reports a failure" 'any(.status.conditions[]?; .type == "Failing" and .status == "False")'
}

nodes_ready() {
  check_ready nodes "Expected five nodes" '.items | length == 5' || return 1
  check_ready nodes "Expected three control-plane nodes" \
    '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane"))] | length == 3' || return 1
  check_ready nodes "Expected two worker nodes" \
    '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/worker"))] | length == 2' || return 1
  check_ready nodes "Some nodes are not s390x" 'all(.items[]; .status.nodeInfo.architecture == "s390x")' || return 1
  check_ready nodes "Some nodes are being deleted" 'all(.items[]; .metadata.deletionTimestamp == null)' || return 1
  check_ready nodes "Some nodes are not Ready" \
    'all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))'
}

operators_ready() {
  check_ready operators "No cluster operators reported" '.items | length > 0' || return 1
  check_ready operators "Some cluster operators are unavailable" \
    'all(.items[]; any(.status.conditions[]?; .type == "Available" and .status == "True"))' || return 1
  check_ready operators "Some cluster operators are progressing" \
    'all(.items[]; any(.status.conditions[]?; .type == "Progressing" and .status == "False"))' || return 1
  check_ready operators "Some cluster operators are degraded" \
    'all(.items[]; any(.status.conditions[]?; .type == "Degraded" and .status == "False"))'
}

# 2. Poll the live cluster. Identity mismatch fails immediately; other readiness
# checks may settle over time, so they keep polling within the same deadline.
while (( SECONDS - started < budget )); do
  if oc --request-timeout=30s get clusterversion version -o json > "$tmp/version" 2>/dev/null; then
    # Wrong-cluster access is terminal, not something to poll until it looks ready.
    jq -e --slurpfile expected "$expected" '.spec.clusterID == $expected[0].cluster_id' \
      "$tmp/version" >/dev/null 2>&1 || fail "Kubeconfig points to a different cluster identity"
    reason="Could not read node or cluster operator status"
    if oc --request-timeout=30s get nodes -o json > "$tmp/nodes" 2>/dev/null &&
       oc --request-timeout=30s get clusteroperators -o json > "$tmp/operators" 2>/dev/null &&
       release_ready && nodes_ready && operators_ready; then
      # 3. All checks passed. The EXIT trap writes the public verification summary.
      outcome=ready
      echo "Verified the new cluster identity, release, HA s390x nodes and cluster operators"
      exit 0
    fi
  else
    reason="Cluster API is not reachable"
  fi
  (( SECONDS - started + 15 < budget )) || break
  sleep 15
done
fail "Cluster readiness deadline exceeded: $reason; retain the cluster for infrastructure diagnosis"
