#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Creates a node-density-heavy workload with kube-burner-ocp and leaves it in
# the cluster (--gc=false). Ensures the step takes TOTAL_ELAPSED_SECONDS in
# total by sleeping for the remainder after kube-burner-ocp finishes, so the
# workload sits in the cluster before subsequent day0 measurement steps run.

echo "=== netobserv-day0-create-workload ==="
echo "  PODS_PER_NODE=${PODS_PER_NODE}"
echo "  TOTAL_ELAPSED_SECONDS=${TOTAL_ELAPSED_SECONDS}"
echo "  KUBE_BURNER_OCP_VERSION=${KUBE_BURNER_OCP_VERSION}"

START_TIME=$(date +%s)

tmp_dir=$(mktemp -d)
pushd "${tmp_dir}"

kube_burner_url="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_OCP_VERSION}/kube-burner-ocp-V${KUBE_BURNER_OCP_VERSION}-linux-x86_64.tar.gz"
echo "Downloading kube-burner-ocp from ${kube_burner_url}"
curl --fail --retry 8 -sS -L "${kube_burner_url}" | tar -xzC "${tmp_dir}/" kube-burner-ocp

echo "Running kube-burner-ocp node-density-heavy (pods will NOT be garbage collected)"
./kube-burner-ocp node-density-heavy \
    --pods-per-node="${PODS_PER_NODE}" \
    --local-indexing \
    --gc=false

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
