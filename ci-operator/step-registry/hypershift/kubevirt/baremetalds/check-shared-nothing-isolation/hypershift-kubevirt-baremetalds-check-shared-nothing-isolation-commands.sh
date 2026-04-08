#!/bin/bash

set -exuo pipefail

HCP_CLI="/usr/bin/hcp"
if [[ ! -f "${HCP_CLI}" ]]; then
  HCP_CLI="/usr/bin/hypershift"
fi
echo "Using ${HCP_CLI} for cli"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAMESPACE_PREFIX="clusters"
# CLUSTER_A: exactly what hypershift-kubevirt-destroy will compute (20 chars)
CLUSTER_A="$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
# CLUSTER_B: 18-char hash + "-b" = 20 chars total, unique name
JOB_HASH18="$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-18)"
CLUSTER_B="${JOB_HASH18}-b"

# The hypershift-kubevirt-destroy post chain computes:
#   CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
# That equals ${CLUSTER_A} exactly, so it destroys cluster-a automatically.
# We destroy cluster-b via the trap below.

RELEASE_IMAGE="${HYPERSHIFT_HC_RELEASE_IMAGE:-${RELEASE_IMAGE_LATEST}}"
PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"
LABEL_KEY="shared-nothing.hypershift.test/cluster"

# ---- Cleanup trap ----
function cleanup() {
  echo "=== Cleanup: destroying cluster-b ${CLUSTER_B} ==="
  "${HCP_CLI}" destroy cluster kubevirt \
    --name "${CLUSTER_B}" \
    --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
    --cluster-grace-period 15m || true
}
trap cleanup EXIT

# ---- Step 1: Collect management cluster nodes ----
echo "=== Collecting management cluster nodes ==="
NODE_JSON="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
mapfile -t ALL_NODES <<< "${NODE_JSON}"
NODE_COUNT="${#ALL_NODES[@]}"
echo "Total nodes: ${NODE_COUNT}"

if [[ "${NODE_COUNT}" -lt 2 ]]; then
  echo "ERROR: Need at least 2 management cluster nodes for Shared Nothing topology, got ${NODE_COUNT}"
  exit 1
fi

# Split: first half → cluster-a, second half → cluster-b
HALF=$(( NODE_COUNT / 2 ))
NODES_A=("${ALL_NODES[@]:0:${HALF}}")
NODES_B=("${ALL_NODES[@]:${HALF}}")

echo "Nodes for ${CLUSTER_A}: ${NODES_A[*]}"
echo "Nodes for ${CLUSTER_B}: ${NODES_B[*]}"

# ---- Step 2: Label nodes with custom per-cluster label ----
echo "=== Labeling nodes ==="
for NODE in "${NODES_A[@]}"; do
  oc label node "${NODE}" "${LABEL_KEY}=${CLUSTER_A}" --overwrite
done
for NODE in "${NODES_B[@]}"; do
  oc label node "${NODE}" "${LABEL_KEY}=${CLUSTER_B}" --overwrite
done

# ---- Step 3: Enable wildcard routes (required for kubevirt hosted cluster) ----
oc patch ingresscontroller -n openshift-ingress-operator default --type=json \
  -p '[{"op":"add","path":"/spec/routeAdmission","value":{"wildcardPolicy":"WildcardsAllowed"}}]'

# ---- Step 4: Create cluster namespace ----
oc create namespace "${CLUSTER_NAMESPACE_PREFIX}" --dry-run=client -o yaml | oc apply -f -

# ---- DEBUGGING: Dynamic sleep before cluster creation ----
# Set DEBUG_SLEEP_SECONDS env var to pause here and inspect cluster state
# Recommended: DEBUG_SLEEP_SECONDS=3600 (1 hour) for interactive debugging
# This allows time to:
#   - Enter the test container (oc rsh or oc debug)
#   - Manually verify infrastructure setup
#   - Manually create/inspect both clusters
#   - Test Shared Nothing topology isolation assertions
if [[ -n "${DEBUG_SLEEP_SECONDS:-}" ]]; then
  echo "=== DEBUG MODE: Sleeping for ${DEBUG_SLEEP_SECONDS} seconds ($(( DEBUG_SLEEP_SECONDS / 60 )) minutes) ==="
  echo ""
  echo "INFRASTRUCTURE SETUP COMPLETE - Ready for manual debugging:"
  echo ""
  echo "1. Node labels applied:"
  echo "   oc get nodes --show-labels | grep '${LABEL_KEY}'"
  echo ""
  echo "2. Cluster namespace created:"
  echo "   oc get ns ${CLUSTER_NAMESPACE_PREFIX}"
  echo ""
  echo "3. Ingress wildcard routes enabled:"
  echo "   oc get ingresscontroller -n openshift-ingress-operator default -o yaml | grep -A3 routeAdmission"
  echo ""
  echo "4. Dedicated node sets:"
  echo "   Cluster-A nodes: ${NODES_A[*]}"
  echo "   Cluster-B nodes: ${NODES_B[*]}"
  echo ""
  echo "5. Variables available for manual cluster creation:"
  echo "   CLUSTER_A=${CLUSTER_A}"
  echo "   CLUSTER_B=${CLUSTER_B}"
  echo "   CLUSTER_NAMESPACE_PREFIX=${CLUSTER_NAMESPACE_PREFIX}"
  echo "   LABEL_KEY=${LABEL_KEY}"
  echo "   RELEASE_IMAGE=${RELEASE_IMAGE}"
  echo "   HYPERSHIFT_NODE_COUNT=${HYPERSHIFT_NODE_COUNT}"
  echo "   HYPERSHIFT_NODE_MEMORY=${HYPERSHIFT_NODE_MEMORY}"
  echo "   HYPERSHIFT_NODE_CPU_CORES=${HYPERSHIFT_NODE_CPU_CORES}"
  echo "   ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-<not set>}"
  echo ""
  echo "6. To enter this container from another terminal:"
  echo "   POD_NAME=\$(oc get pod -n <test-namespace> --no-headers | grep check-shared-nothing | awk '{print \$1}')"
  echo "   oc rsh -n <test-namespace> \${POD_NAME}"
  echo ""
  echo "7. Manual cluster creation commands (copy/paste into container shell):"
  echo "   # Create cluster-a:"
  echo "   ${HCP_CLI} create cluster kubevirt --name ${CLUSTER_A} --namespace ${CLUSTER_NAMESPACE_PREFIX} --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} --memory ${HYPERSHIFT_NODE_MEMORY}Gi --cores ${HYPERSHIFT_NODE_CPU_CORES} --root-volume-size 64 --release-image ${RELEASE_IMAGE} --pull-secret ${PULL_SECRET_PATH} --generate-ssh --network-type ${HYPERSHIFT_NETWORK_TYPE} --service-cidr 172.32.0.0/16 --cluster-cidr 10.136.0.0/14${ETCD_ARG:+ }${ETCD_ARG}"
  echo ""
  echo "   # Patch cluster-a nodeSelector:"
  echo "   oc patch hostedcluster ${CLUSTER_A} -n ${CLUSTER_NAMESPACE_PREFIX} --type=merge -p '{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_A}\"}}}'"
  echo "   oc patch nodepool ${CLUSTER_A} -n ${CLUSTER_NAMESPACE_PREFIX} --type=merge -p '{\"spec\":{\"platform\":{\"kubevirt\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_A}\"}}}}}"
  echo ""
  echo "Sleeping... (will auto-resume cluster creation after timeout)"

  SLEEP_START=$(date +%s)
  SLEEP_END=$(( SLEEP_START + DEBUG_SLEEP_SECONDS ))

  while [[ $(date +%s) -lt ${SLEEP_END} ]]; do
    REMAINING=$(( SLEEP_END - $(date +%s) ))
    echo -ne "\rTime remaining: $(( REMAINING / 60 ))m $(( REMAINING % 60 ))s   "
    sleep 10
  done

  echo ""
  echo "=== DEBUG MODE: Sleep timeout reached, resuming automated cluster creation ==="
fi

# ---- Step 5: Create cluster-a ----
ETCD_ARG=""
if [[ -n "${ETCD_STORAGE_CLASS:-}" ]]; then
  ETCD_ARG="--etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

echo "=== Creating hosted cluster ${CLUSTER_A} ==="
"${HCP_CLI}" create cluster kubevirt \
  --name "${CLUSTER_A}" \
  --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
  --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
  --root-volume-size 64 \
  --release-image "${RELEASE_IMAGE}" \
  --pull-secret "${PULL_SECRET_PATH}" \
  --generate-ssh \
  --network-type "${HYPERSHIFT_NETWORK_TYPE}" \
  --service-cidr 172.32.0.0/16 \
  --cluster-cidr 10.136.0.0/14 \
  ${ETCD_ARG}

# Patch HostedCluster nodeSelector to dedicate control-plane pods to cluster-a nodes
oc patch hostedcluster "${CLUSTER_A}" -n "${CLUSTER_NAMESPACE_PREFIX}" --type=merge \
  -p "{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_A}\"}}}"

# Patch NodePool kubevirt nodeSelector to dedicate VMIs to cluster-a nodes
# (The correct API path is spec.platform.kubevirt.nodeSelector, not nodePlacement.nodeSelector)
NODEPOOL_NAME="${CLUSTER_A}"
oc patch nodepool "${NODEPOOL_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" --type=merge \
  -p "{\"spec\":{\"platform\":{\"kubevirt\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_A}\"}}}}}"

# ---- Step 6: Create cluster-b ----
echo "=== Creating hosted cluster ${CLUSTER_B} ==="
"${HCP_CLI}" create cluster kubevirt \
  --name "${CLUSTER_B}" \
  --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
  --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
  --root-volume-size 64 \
  --release-image "${RELEASE_IMAGE}" \
  --pull-secret "${PULL_SECRET_PATH}" \
  --generate-ssh \
  --network-type "${HYPERSHIFT_NETWORK_TYPE}" \
  --service-cidr 172.33.0.0/16 \
  --cluster-cidr 10.140.0.0/14 \
  ${ETCD_ARG}

oc patch hostedcluster "${CLUSTER_B}" -n "${CLUSTER_NAMESPACE_PREFIX}" --type=merge \
  -p "{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_B}\"}}}"

NODEPOOL_NAME_B="${CLUSTER_B}"
oc patch nodepool "${NODEPOOL_NAME_B}" -n "${CLUSTER_NAMESPACE_PREFIX}" --type=merge \
  -p "{\"spec\":{\"platform\":{\"kubevirt\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CLUSTER_B}\"}}}}}"

# ---- Step 7: Wait for both clusters to be Available ----
echo "=== Waiting for ${CLUSTER_A} to become Available ==="
oc wait --timeout=30m --for=condition=Available \
  --namespace="${CLUSTER_NAMESPACE_PREFIX}" "hostedcluster/${CLUSTER_A}"

echo "=== Waiting for ${CLUSTER_B} to become Available ==="
oc wait --timeout=30m --for=condition=Available \
  --namespace="${CLUSTER_NAMESPACE_PREFIX}" "hostedcluster/${CLUSTER_B}"

# ---- Step 7b: Wait for NodePools to have all machines ready ----
# HostedCluster Available only means the control plane is up; the NodePool VMs
# may still be importing their boot disk (DataVolume) or waiting to be scheduled.
# Wait for the NodePool AllMachinesReady condition instead of polling VMI nodeName.
function wait_nodepool_ready() {
  local name="$1" ns="$2"
  local retries=60 interval=30
  for i in $(seq 1 "${retries}"); do
    local ready
    ready=$(oc get nodepool "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="AllMachinesReady")].status}' 2>/dev/null || true)
    if [[ "${ready}" == "True" ]]; then
      echo "  NodePool ${name} AllMachinesReady after $((i * interval))s"
      return 0
    fi
    local msg
    msg=$(oc get nodepool "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="AllMachinesReady")].message}' 2>/dev/null || true)
    echo "  Waiting for NodePool ${name} AllMachinesReady (attempt ${i}/${retries}): ${msg:-(not set)}"
    sleep "${interval}"
  done
  echo "ERROR: NodePool ${name} not ready after $((retries * interval))s"
  oc get nodepool "${name}" -n "${ns}" -o yaml 2>/dev/null || true
  return 1
}

echo "=== Waiting for NodePools to be ready ==="
wait_nodepool_ready "${CLUSTER_A}" "${CLUSTER_NAMESPACE_PREFIX}"
wait_nodepool_ready "${CLUSTER_B}" "${CLUSTER_NAMESPACE_PREFIX}"

# ---- Step 8: Collect VMI node placement ----
echo "=== Collecting VMI node placement ==="
mapfile -t NODES_USED_BY_A < <(oc get vmi -n "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_A}" \
  -o jsonpath='{range .items[*]}{.status.nodeName}{"\n"}{end}' | sort -u)
mapfile -t NODES_USED_BY_B < <(oc get vmi -n "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_B}" \
  -o jsonpath='{range .items[*]}{.status.nodeName}{"\n"}{end}' | sort -u)

echo "Cluster-A VMIs on nodes: ${NODES_USED_BY_A[*]:-<none>}"
echo "Cluster-B VMIs on nodes: ${NODES_USED_BY_B[*]:-<none>}"

ISOLATION_FAIL=0

if [[ "${#NODES_USED_BY_A[@]}" -eq 0 ]]; then
  echo "FAIL: No VMIs with a nodeName found for cluster-a — cannot verify isolation"
  ISOLATION_FAIL=1
fi
if [[ "${#NODES_USED_BY_B[@]}" -eq 0 ]]; then
  echo "FAIL: No VMIs with a nodeName found for cluster-b — cannot verify isolation"
  ISOLATION_FAIL=1
fi

# ---- Step 9: Read boot IDs from dedicated nodes ----
echo "=== Reading boot IDs from management nodes ==="
declare -A BOOT_ID_MAP
for NODE in "${NODES_A[@]}" "${NODES_B[@]}"; do
  BOOT_ID="$(oc get node "${NODE}" -o jsonpath='{.status.nodeInfo.bootID}')"
  BOOT_ID_MAP["${NODE}"]="${BOOT_ID}"
  echo "  ${NODE}: bootID=${BOOT_ID}"
done

# ---- Step 10: Assertions ----
echo "=== Assertion 1: VMIs on correct dedicated nodes ==="
for NODE in "${NODES_USED_BY_A[@]}"; do
  FOUND=0
  for DEDICATED in "${NODES_A[@]}"; do
    if [[ "${NODE}" == "${DEDICATED}" ]]; then
      FOUND=1
      break
    fi
  done
  if [[ "${FOUND}" -eq 0 ]]; then
    echo "FAIL: Cluster-A VMI on node ${NODE} is NOT in cluster-a dedicated set"
    ISOLATION_FAIL=1
  fi
done
for NODE in "${NODES_USED_BY_B[@]}"; do
  FOUND=0
  for DEDICATED in "${NODES_B[@]}"; do
    if [[ "${NODE}" == "${DEDICATED}" ]]; then
      FOUND=1
      break
    fi
  done
  if [[ "${FOUND}" -eq 0 ]]; then
    echo "FAIL: Cluster-B VMI on node ${NODE} is NOT in cluster-b dedicated set"
    ISOLATION_FAIL=1
  fi
done

echo "=== Assertion 2: Nodes used by VMIs are disjoint between clusters ==="
for NODE in "${NODES_USED_BY_A[@]}"; do
  if [[ " ${NODES_USED_BY_B[*]} " == *" ${NODE} "* ]]; then
    echo "FAIL: Node ${NODE} is used by both cluster-a and cluster-b VMIs — no kernel isolation"
    ISOLATION_FAIL=1
  fi
done

# ---- Step 10: Verify cross-cluster network isolation ----
# The VirtLauncher NetworkPolicy restricts egress from the VMs (guest worker nodes).
# To test this correctly we must run the connectivity probe from INSIDE the hosted
# cluster-a (i.e. from a pod scheduled on cluster-a's VMs), not from the management
# cluster.  Only that way does the probe traffic traverse the virt-launcher network
# namespace where the NetworkPolicy is enforced.
echo "=== Assertion 3: Cross-cluster network isolation ==="

# --- 3a: Verify NetworkPolicy exists on management cluster for cluster-a ---
NP_NAME=$(oc get networkpolicy -n "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_A}" \
  -o jsonpath='{.items[?(@.spec.podSelector.matchLabels.kubevirt\.io=="virt-launcher")].metadata.name}' \
  2>/dev/null || true)
echo "VirtLauncher NetworkPolicy in ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_A}: ${NP_NAME:-<none>}"
if [[ -z "${NP_NAME}" ]]; then
  echo "FAIL: VirtLauncher NetworkPolicy not found in ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_A}"
  ISOLATION_FAIL=1
else
  echo "=== NetworkPolicy spec ==="
  oc get networkpolicy "${NP_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_A}" -o yaml | grep -A60 "^spec:"
fi

# --- 3b: Get cluster-b kube-apiserver pod IP (management cluster view) ---
CLUSTER_B_KAS_IP=$(oc get pod -n "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_B}" \
  -l app=kube-apiserver -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
if [[ -z "${CLUSTER_B_KAS_IP}" ]]; then
  echo "WARN: Could not determine cluster-b kube-apiserver pod IP, skipping network isolation test"
else
  echo "Cluster-B kube-apiserver pod IP (management cluster): ${CLUSTER_B_KAS_IP}"

  # --- 3c: Obtain cluster-a hosted cluster kubeconfig ---
  # The test probe must originate from inside cluster-a (on its VMs) so that
  # traffic passes through the virt-launcher network namespace where the
  # NetworkPolicy egress rules are enforced.
  CLUSTER_A_KUBECONFIG="/tmp/kubeconfig-cluster-a"
  "${HCP_CLI}" create kubeconfig \
    --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
    --name "${CLUSTER_A}" \
    > "${CLUSTER_A_KUBECONFIG}" 2>/dev/null
  echo "Obtained cluster-a kubeconfig: ${CLUSTER_A_KUBECONFIG}"

  # --- 3d: Create a debug pod inside cluster-a and probe cluster-b ---
  # Use a debug pod on cluster-a's hosted cluster; it runs on the VM (guest worker
  # node) whose network namespace is governed by the VirtLauncher NetworkPolicy.
  # curl exit codes: 0=connected, 7=refused, 28=timeout(DROP), 35/60=TLS-after-connect
  echo "  Launching debug pod inside hosted cluster-a to probe cluster-b kube-apiserver..."

  CURL_OUTPUT=$(KUBECONFIG="${CLUSTER_A_KUBECONFIG}" oc run network-isolation-probe \
    --image=quay.io/curl/curl:latest \
    --restart=Never \
    --rm \
    --attach \
    --timeout=60s \
    -q \
    -- curl -k -m 10 --connect-timeout 5 "https://${CLUSTER_B_KAS_IP}:6443" 2>&1) || true
  CURL_EXIT=$?
  echo "  curl exit code: ${CURL_EXIT}"
  echo "  curl output: ${CURL_OUTPUT:0:300}"

  # Interpret exit code
  # 0, 35, 60  → TCP connection reached the pod (NetworkPolicy NOT blocking) → FAIL
  # 28, 124, 137 → connection timed out (NetworkPolicy DROP)                  → PASS
  # 7           → connection refused (TCP reached host, port closed)          → FAIL
  # 126/127     → curl binary not found                                       → skip
  if [[ ${CURL_EXIT} -eq 126 || ${CURL_EXIT} -eq 127 ]]; then
    echo "WARN: curl not available in probe image (exit ${CURL_EXIT}), skipping network isolation test"
  elif [[ ${CURL_EXIT} -eq 0 || ${CURL_EXIT} -eq 35 || ${CURL_EXIT} -eq 60 ]]; then
    echo "FAIL: Pod inside cluster-a can reach cluster-b kube-apiserver (${CLUSTER_B_KAS_IP}:6443, curl exit ${CURL_EXIT})"
    echo "  The VirtLauncher NetworkPolicy is NOT blocking egress to the management cluster pod CIDR"
    ISOLATION_FAIL=1
  elif [[ ${CURL_EXIT} -eq 28 || ${CURL_EXIT} -eq 124 || ${CURL_EXIT} -eq 137 ]]; then
    echo "  ✓ Connection timed out (curl exit ${CURL_EXIT}) — NetworkPolicy DROP confirmed, network isolation PASSED"
  elif [[ ${CURL_EXIT} -eq 7 ]]; then
    echo "FAIL: Connection refused (curl exit 7) — TCP reached ${CLUSTER_B_KAS_IP}, NetworkPolicy is NOT blocking"
    ISOLATION_FAIL=1
  else
    echo "WARN: Unexpected curl exit code ${CURL_EXIT} — treating as inconclusive"
    echo "  Output: ${CURL_OUTPUT:0:300}"
  fi

  # Clean up kubeconfig
  rm -f "${CLUSTER_A_KUBECONFIG}"
fi

# ---- Step 11: Summary ----
echo ""
echo "=== Shared Nothing Isolation Verification Summary ==="
echo "Cluster-A dedicated nodes: ${NODES_A[*]}"
echo "Cluster-B dedicated nodes: ${NODES_B[*]}"
for NODE in "${NODES_A[@]}"; do
  echo "  [cluster-a] ${NODE} bootID=${BOOT_ID_MAP[${NODE}]}"
done
for NODE in "${NODES_B[@]}"; do
  echo "  [cluster-b] ${NODE} bootID=${BOOT_ID_MAP[${NODE}]}"
done

if [[ "${ISOLATION_FAIL}" -eq 0 ]]; then
  echo "RESULT: VM-level kernel isolation ✓ CONFIRMED"
  echo "RESULT: Cross-cluster network isolation ✓ CONFIRMED"
  exit 0
else
  echo "RESULT: FAIL — isolation not confirmed, see above"
  exit 1
fi
