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

# Record which etcd topology produced the results. With sharding each shard is
# its own StatefulSet (etcd, etcd-events, etcd-leases, ...), so this is also the
# record of which shards the metrics below are coming from. No label selector:
# the StatefulSet objects carry no "app" label, and the per-shard pods label
# themselves with their own shard name rather than a common value.
mc get statefulset -n "${HCP_NAMESPACE}" -o wide 2>&1 \
    | tee "${ARTIFACT_DIR}/etcd-statefulsets.txt" || true
mc get hostedcluster -n clusters "${CLUSTER_NAME}" -o jsonpath='{.spec.etcd}' \
    > "${ARTIFACT_DIR}/hostedcluster-etcd-spec.json" 2>/dev/null || true

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

# Fail now rather than after a multi-hour workload that produced no measurement.
#
# etcd_server_leader_changes_seen_total rather than a more obvious liveness
# series such as etcd_server_has_leader: the hosted control plane's etcd
# ServiceMonitor drops everything outside a keep list unless the HyperShift
# operator was installed with --metrics-set=All, and this metric is one of the
# few that is in the keep list of every metrics set. It is also one series per
# member, so counting it counts members.
#
# Polled rather than slept: user workload monitoring is usually enabled moments
# before this step by hypershift-enable-user-workload-monitoring, so Prometheus
# has to start, pick up the ServiceMonitors and complete a scrape before
# anything can be returned. A fixed sleep either races that or wastes time.
probe() {
    local response
    response="$(promq "count(etcd_server_leader_changes_seen_total{namespace=\"${HCP_NAMESPACE}\"})")" || return 1
    jq -r '.data.result[0].value[1] // empty' <<< "${response}"
}

echo "Waiting up to ${SCRAPE_WAIT_SECONDS}s for the hosted control plane etcd targets to be scraped"
series_count=""
deadline=$(( SECONDS + SCRAPE_WAIT_SECONDS ))
while (( SECONDS < deadline )); do
    series_count="$(probe || true)"
    [[ -n "${series_count}" && "${series_count}" != "0" ]] && break
    sleep "${SCRAPE_POLL_INTERVAL}"
done

if [[ -z "${series_count}" || "${series_count}" == "0" ]]; then
    echo "FATAL: Thanos returned no etcd metrics for namespace ${HCP_NAMESPACE}"
    echo "within ${SCRAPE_WAIT_SECONDS}s. Check that user workload monitoring came up"
    echo "(hypershift-enable-user-workload-monitoring) and that the hosted control"
    echo "plane's etcd ServiceMonitors exist and are being scraped."
    mc get servicemonitor -n "${HCP_NAMESPACE}" 2>&1 | head -20 || true
    mc get pods -n openshift-user-workload-monitoring 2>&1 | head -20 || true
    exit 1
fi
echo "Scraping ${series_count} etcd member(s) in ${HCP_NAMESPACE}"

# The profiles query etcd_cluster_version, which only the "All" metrics set
# keeps. Warn rather than fail: every other query in the profile works without
# it, so this is a gap in the results, not a reason to throw the run away.
if [[ -z "$(promq 'count(etcd_cluster_version)' | jq -r '.data.result[0].value[1] // empty')" ]]; then
    echo "WARNING: etcd_cluster_version is not being collected, so the metrics set is"
    echo "restricted. Install the HyperShift operator with METRICS_SET=All to collect"
    echo "the full etcd and kube-apiserver series."
fi

# ---------------------------------------------------------------------------
# Endpoint file
#
# Written to SHARED_DIR, never to ARTIFACT_DIR: it carries the bearer token.
#
# Two entries over the same endpoint and the same profiles, because an entry
# carries exactly one indexer:
#
#   - Elasticsearch, which is what the perf and scale Grafana dashboards read.
#     This is where the results of a run are looked at.
#   - local, so the same series are also in collected-metrics-<uuid>/ in the
#     job artifacts and a failed run can be read without an ES query.
#
# No credential is written here. kube-burner renders this file as a Go
# template over the environment before parsing it, the same way the upstream
# metrics-endpoint.yml does, so ES_SERVER stays in the openshift-qe workload
# step that already owns it and never reaches this step or the filesystem.
# ---------------------------------------------------------------------------
endpoint_entry() {
    echo "- endpoint: ${THANOS_URL}"
    echo "  token: ${PROM_TOKEN}"
    echo "  skipTLSVerify: true"
    echo "  step: ${METRICS_STEP}"
    echo "  metrics:"
    for profile in ${HCP_METRICS_PROFILES}; do
        echo "  - ${profile}"
    done
    echo "  indexer:"
}

ENDPOINT_FILE="${SHARED_DIR}/hcp-metrics-endpoint.yml"
{
    endpoint_entry
    echo "    type: opensearch"
    echo "    esServers: [\"{{.ES_SERVER}}\"]"
    echo "    defaultIndex: {{.ES_INDEX}}"
    echo "    insecureSkipVerify: true"

    endpoint_entry
    echo "    type: local"
    # UUID is exported by the openshift-qe workload step, and the directory
    # name is the one that step copies into ARTIFACT_DIR when the run finishes.
    echo "    metricsDirectory: collected-metrics-{{.UUID}}"
} > "${ENDPOINT_FILE}"
chmod 600 "${ENDPOINT_FILE}"

echo "Metrics profiles: ${HCP_METRICS_PROFILES}"

echo "${HCP_NAMESPACE}" > "${SHARED_DIR}/hcp-namespace"
echo "Wrote ${ENDPOINT_FILE}"
