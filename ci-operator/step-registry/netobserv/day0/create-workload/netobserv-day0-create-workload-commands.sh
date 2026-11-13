#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Creates a workload with kube-burner-ocp and leaves it in the cluster
# (--gc=false). The workload type is selected from the worker node count:
# small clusters (up to SMALL_CLUSTER_MAX_WORKERS) run node-density-heavy
# with PODS_PER_NODE pods per node, while larger clusters run
# cluster-density-v2 with iterations derived from the worker count to reach
# PODS_PER_WORKER pods per worker (node-density-heavy at high pod counts on
# large clusters overloads etcd). Ensures the step takes
# TOTAL_ELAPSED_SECONDS in total by sleeping for the remainder after
# kube-burner-ocp finishes, so the workload sits in the cluster before
# subsequent day0 measurement steps run.

echo "=== netobserv-day0-create-workload ==="
echo "  PODS_PER_NODE=${PODS_PER_NODE}"
echo "  PODS_PER_WORKER=${PODS_PER_WORKER}"
echo "  SMALL_CLUSTER_MAX_WORKERS=${SMALL_CLUSTER_MAX_WORKERS}"
echo "  TOTAL_ELAPSED_SECONDS=${TOTAL_ELAPSED_SECONDS}"
echo "  KUBE_BURNER_OCP_VERSION=${KUBE_BURNER_OCP_VERSION}"
echo "  KUBE_BURNER_QPS=${KUBE_BURNER_QPS}"
echo "  KUBE_BURNER_BURST=${KUBE_BURNER_BURST}"

START_TIME=$(date +%s)

tmp_dir=$(mktemp -d)
pushd "${tmp_dir}"

kube_burner_url="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_OCP_VERSION}/kube-burner-ocp-V${KUBE_BURNER_OCP_VERSION}-linux-x86_64.tar.gz"
echo "Downloading kube-burner-ocp from ${kube_burner_url}"
curl --fail --retry 8 -sS -L "${kube_burner_url}" | tar -xzC "${tmp_dir}/" kube-burner-ocp

WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | wc -l | tr -d ' ')
if [[ -z "${WORKER_COUNT}" || "${WORKER_COUNT}" -eq 0 ]]; then
    echo "Failed to determine worker node count" >&2
    exit 1
fi
echo "Worker nodes: ${WORKER_COUNT}"

# Common flags for both workload types. A low client-side rate limit keeps
# kube-burner from overwhelming etcd on large clusters, which otherwise leads
# to request timeouts, retried creates hitting AlreadyExists, and a hard job
# failure.
KUBE_BURNER_COMMON_ARGS=(
    --qps=20
    --burst=20
    --local-indexing
    --gc=false
)

if (( WORKER_COUNT <= SMALL_CLUSTER_MAX_WORKERS )); then
    echo "Running kube-burner-ocp node-density-heavy with ${PODS_PER_NODE} pods per node (pods will NOT be garbage collected)"
    ./kube-burner-ocp node-density-heavy \
        --pods-per-node="${PODS_PER_NODE}" \
        "${KUBE_BURNER_COMMON_ARGS[@]}"
else
    # Derive the number of cluster-density-v2 iterations from the worker
    # node count. Each iteration creates roughly PODS_PER_ITERATION pods
    # (application bundle per namespace), so scale iterations to reach
    # PODS_PER_WORKER pods per worker node. Rounded to the nearest 5.
    PODS_PER_ITERATION=25
    ITERATIONS=$(( (WORKER_COUNT * PODS_PER_WORKER / PODS_PER_ITERATION + 2) / 5 * 5 ))
    if [[ "${ITERATIONS}" -lt 5 ]]; then
        ITERATIONS=5
    fi
    echo "Target pods per worker: ${PODS_PER_WORKER}"
    echo "Running kube-burner-ocp cluster-density-v2 with ${ITERATIONS} iterations (pods will NOT be garbage collected)"
    ./kube-burner-ocp cluster-density-v2 \
        --iterations="${ITERATIONS}" \
        "${KUBE_BURNER_COMMON_ARGS[@]}"
fi

popd

KUBE_BURNER_END_TIME=$(date +%s)
KUBE_BURNER_ELAPSED=$((KUBE_BURNER_END_TIME - START_TIME))
echo "kube-burner-ocp finished after ${KUBE_BURNER_ELAPSED}s"

if (( KUBE_BURNER_ELAPSED < TOTAL_ELAPSED_SECONDS )); then
    REMAINING=$((TOTAL_ELAPSED_SECONDS - KUBE_BURNER_ELAPSED))
    echo "Letting workload sit in the cluster for ${REMAINING}s"
    sleep "${REMAINING}"
else
    echo "kube-burner-ocp already ran for ${KUBE_BURNER_ELAPSED}s, no additional soak time needed"
fi

END_TIME=$(date +%s)
echo "Total step elapsed: $((END_TIME - START_TIME))s"
