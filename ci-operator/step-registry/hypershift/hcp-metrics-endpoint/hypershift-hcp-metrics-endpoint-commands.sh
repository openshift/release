#!/bin/bash

set -euo pipefail
# Do not enable `set -x`. This step mints a Prometheus bearer token; tracing
# would put it in the CI logs.

MC_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
for f in "${MC_KUBECONFIG}" "${SHARED_DIR}/cluster-name"; do
    if [[ ! -s "${f}" ]]; then
        echo "FATAL: ${f} is missing or empty; this step needs a hosted cluster to already exist."
        exit 1
    fi
done

CLUSTER_NAME="$(cat "${SHARED_DIR}/cluster-name")"
# HyperShift puts the hosted control plane in "<hostedcluster namespace>-<name>",
# and every CI workflow that feeds this step creates the HostedCluster in "clusters".
HCP_NAMESPACE="clusters-${CLUSTER_NAME}"

mc() { oc --kubeconfig="${MC_KUBECONFIG}" "$@"; }

echo "Hosted cluster:          ${CLUSTER_NAME}"
echo "Hosted control plane ns: ${HCP_NAMESPACE}"

if ! mc get namespace "${HCP_NAMESPACE}" >/dev/null 2>&1; then
    echo "FATAL: namespace ${HCP_NAMESPACE} does not exist on the management cluster."
    exit 1
fi

# Record which etcd topology produced the results. With sharding the pod names
# carry the shard name (etcd-0, etcd-events-0, ...), so this is also the record
# of which shards the metrics below are coming from.
mc get statefulset -n "${HCP_NAMESPACE}" -l app=etcd -o wide 2>&1 \
    | tee "${ARTIFACT_DIR}/etcd-statefulsets.txt" || true
mc get hostedcluster -n clusters "${CLUSTER_NAME}" -o jsonpath='{.spec.etcd}' \
    > "${ARTIFACT_DIR}/hostedcluster-etcd-spec.json" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Metrics profiles
#
# Taken from the kube-burner-ocp wrapper in e2e-benchmarking rather than
# written here, so the queries stay owned by the perf and scale team and this
# repo does not carry a second copy that drifts. The profiles are copied into
# SHARED_DIR because /tmp does not survive into the step that runs the
# workload.
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
if [[ "${E2E_VERSION}" == "default" ]]; then
    E2E_REF="$(git ls-remote --tags "${REPO_URL}.git" \
        | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)"
else
    E2E_REF="${E2E_VERSION}"
fi
echo "Using e2e-benchmarking ${E2E_REF} for the metrics profiles"
git clone "${REPO_URL}" --branch "${E2E_REF}" --depth 1 /tmp/e2e-benchmarking

WRAPPER=/tmp/e2e-benchmarking/workloads/kube-burner-ocp-wrapper
PROFILE_DIR="${SHARED_DIR}/hcp-metrics-profiles"
mkdir -p "${PROFILE_DIR}"

for profile in ${HCP_METRICS_PROFILES}; do
    src="${WRAPPER}/metrics-profiles/${profile}"
    if [[ ! -s "${src}" ]]; then
        echo "FATAL: ${profile} does not exist in e2e-benchmarking ${E2E_REF}."
        exit 1
    fi
    # The upstream profiles are written for ROSA, where the hosted control plane
    # namespace is "<infraID>-<name>" and the queries match it with
    # namespace=~".+{{.HCP_NAMESPACE}}". Self-managed HyperShift uses
    # "clusters-<name>", so binding the placeholder to the cluster name keeps the
    # upstream regex correct without editing the queries.
    sed "s|{{\.HCP_NAMESPACE}}|${CLUSTER_NAME}|g" "${src}" > "${PROFILE_DIR}/$(basename "${profile}")"
done
cp -r "${PROFILE_DIR}" "${ARTIFACT_DIR}/hcp-metrics-profiles"

# ---------------------------------------------------------------------------
# Thanos endpoint and token
#
# thanos-querier rather than prometheus-k8s: the hosted control plane series are
# collected by the user workload Prometheus, and thanos-querier is the endpoint
# that serves both stacks.
# ---------------------------------------------------------------------------
PROM_SA="hypershift-hcp-metrics"
mc -n openshift-monitoring create serviceaccount "${PROM_SA}" --dry-run=client -o yaml | mc apply -f -
mc adm policy add-cluster-role-to-user cluster-monitoring-view \
    -z "${PROM_SA}" -n openshift-monitoring >/dev/null

THANOS_HOST="$(mc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')"
if [[ -z "${THANOS_HOST}" ]]; then
    echo "FATAL: could not resolve the thanos-querier route on the management cluster."
    exit 1
fi
THANOS_URL="https://${THANOS_HOST}"
PROM_TOKEN="$(mc -n openshift-monitoring create token "${PROM_SA}" --duration="${PROM_TOKEN_DURATION}")"
echo "Thanos endpoint: ${THANOS_URL}"

# The management cluster's ingress certificate is not one this container trusts,
# hence -k here and skipTLSVerify in the endpoint file below.
promq() {
    curl --fail --silent --show-error -k --get --data-urlencode "query=$1" \
        -H "Authorization: Bearer ${PROM_TOKEN}" \
        "${THANOS_URL}/api/v1/query"
}

echo "Waiting ${SCRAPE_SETTLE_SECONDS}s for the hosted control plane targets to be scraped"
sleep "${SCRAPE_SETTLE_SECONDS}"

# Fail now rather than after a multi-hour workload that produced no measurement.
# A query that errors, returns no result, or returns zero members all mean the
# same thing here: there is nothing to measure.
if ! response="$(promq "count(etcd_server_has_leader{namespace=\"${HCP_NAMESPACE}\"})")"; then
    echo "FATAL: the Thanos query failed. The endpoint or the token is wrong, or"
    echo "thanos-querier on the management cluster is not serving queries."
    exit 1
fi
series_count="$(jq -r '.data.result[0].value[1] // empty' <<< "${response}")"
if [[ -z "${series_count}" || "${series_count}" == "0" ]]; then
    echo "FATAL: Thanos returns no etcd metrics for namespace ${HCP_NAMESPACE}."
    echo "Check that the hosted control plane's etcd ServiceMonitors exist and that"
    echo "user workload monitoring came up (hypershift-enable-user-workload-monitoring)."
    mc get servicemonitor -n "${HCP_NAMESPACE}" 2>&1 | head -20 || true
    exit 1
fi
echo "Scraping ${series_count} etcd member(s) in ${HCP_NAMESPACE}"

# ---------------------------------------------------------------------------
# Endpoint file
#
# Written to SHARED_DIR, never to ARTIFACT_DIR: it carries the bearer token.
# The indexer is local so the series land in the workload step's working
# directory and from there in the artifacts; indexing to Elasticsearch stays
# with the openshift-qe workload step, which already owns those credentials.
# ---------------------------------------------------------------------------
ENDPOINT_FILE="${SHARED_DIR}/hcp-metrics-endpoint.yml"
{
    echo "- endpoint: ${THANOS_URL}"
    echo "  token: ${PROM_TOKEN}"
    echo "  skipTLSVerify: true"
    echo "  step: ${METRICS_STEP}"
    echo "  metrics:"
    for profile in ${HCP_METRICS_PROFILES}; do
        echo "  - ${PROFILE_DIR}/$(basename "${profile}")"
    done
    echo "  indexer:"
    echo "    type: local"
    # kube-burner renders the endpoint file as a template over the environment,
    # the same way the upstream metrics-endpoint.yml uses {{.ES_SERVER}}. UUID is
    # exported by the openshift-qe workload step, and the directory name is the
    # one that step copies into ARTIFACT_DIR when the run finishes.
    echo "    metricsDirectory: collected-metrics-{{.UUID}}"
} > "${ENDPOINT_FILE}"
chmod 600 "${ENDPOINT_FILE}"

echo "${HCP_NAMESPACE}" > "${SHARED_DIR}/hcp-namespace"
echo "Wrote ${ENDPOINT_FILE}"
