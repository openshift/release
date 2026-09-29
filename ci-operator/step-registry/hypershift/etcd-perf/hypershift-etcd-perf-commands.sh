#!/bin/bash

set -euo pipefail
# Do not enable `set -x`. This script mints a Prometheus bearer token and reads
# Elasticsearch credentials; tracing would put both in the CI logs.

MC_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
GUEST_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

for f in "${MC_KUBECONFIG}" "${GUEST_KUBECONFIG}" "${SHARED_DIR}/cluster-name"; do
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

echo "Hosted cluster:            ${CLUSTER_NAME}"
echo "Hosted control plane ns:   ${HCP_NAMESPACE}"
echo "Workload:                  etcd-density ${ETCD_PERF_WORKLOAD}"
echo "Shard topology variant:    ${ETCD_PERF_VARIANT}"

if ! mc get namespace "${HCP_NAMESPACE}" >/dev/null 2>&1; then
    echo "FATAL: namespace ${HCP_NAMESPACE} does not exist on the management cluster."
    exit 1
fi

echo
echo "=== etcd shards in ${HCP_NAMESPACE} ==="
# Recorded so the artifacts say which topology produced them. With sharding the
# pod names carry the shard name (etcd-0, etcd-events-0, ...), which is what
# makes the "by (pod)" breakdown in the metrics profile a per-shard breakdown.
mc get statefulset -n "${HCP_NAMESPACE}" -l app=etcd -o wide 2>/dev/null || true
mc get pods -n "${HCP_NAMESPACE}" -l app=etcd -o name 2>/dev/null | tee "${ARTIFACT_DIR}/etcd-pods.txt" || true
mc get hostedcluster -n clusters "${CLUSTER_NAME}" -o jsonpath='{.spec.etcd}' \
    > "${ARTIFACT_DIR}/hostedcluster-etcd-spec.json" 2>/dev/null || true
echo

# ---------------------------------------------------------------------------
# Management cluster monitoring
#
# The hosted control plane's etcd and kube-apiserver run as ordinary workloads
# in ${HCP_NAMESPACE}, so their ServiceMonitors are only scraped if user
# workload monitoring is on. The management cluster here is ephemeral and
# per-job, so turning it on is safe, but still only do it if it is off.
# ---------------------------------------------------------------------------
enable_user_workload_monitoring() {
    local existing
    if ! existing="$(mc -n openshift-monitoring get configmap cluster-monitoring-config \
        -o jsonpath='{.data.config\.yaml}' 2>/dev/null)"; then
        echo "Creating cluster-monitoring-config with user workload monitoring enabled"
        mc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
        return
    fi

    if grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true' <<< "${existing}"; then
        echo "User workload monitoring is already enabled"
        return
    fi

    echo "Appending enableUserWorkload to the existing cluster-monitoring-config"
    printf '%s\nenableUserWorkload: true\n' "${existing}" > /tmp/cluster-monitoring-config.yaml
    mc -n openshift-monitoring create configmap cluster-monitoring-config \
        --from-file=config.yaml=/tmp/cluster-monitoring-config.yaml \
        --dry-run=client -o yaml | mc replace -f -
}

enable_user_workload_monitoring

echo "Waiting for the user workload Prometheus to come up"
for _ in $(seq 1 60); do
    if mc -n openshift-user-workload-monitoring get statefulset prometheus-user-workload >/dev/null 2>&1; then
        break
    fi
    sleep 10
done
mc -n openshift-user-workload-monitoring rollout status statefulset/prometheus-user-workload --timeout=10m

# ---------------------------------------------------------------------------
# Thanos endpoint and token
# ---------------------------------------------------------------------------
PROM_SA="hypershift-etcd-perf"
mc -n openshift-monitoring create serviceaccount "${PROM_SA}" --dry-run=client -o yaml | mc apply -f -
mc adm policy add-cluster-role-to-user cluster-monitoring-view \
    -z "${PROM_SA}" -n openshift-monitoring >/dev/null

THANOS_HOST="$(mc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')"
if [[ -z "${THANOS_HOST}" ]]; then
    echo "FATAL: could not resolve the thanos-querier route on the management cluster."
    exit 1
fi
THANOS_URL="https://${THANOS_HOST}"
PROM_TOKEN="$(mc -n openshift-monitoring create token "${PROM_SA}" --duration=8h)"
echo "Thanos endpoint: ${THANOS_URL}"

# The management cluster's ingress certificate is not one this container trusts,
# hence -k here and skipTLSVerify in the metrics endpoint below.
promq() {
    curl -sSk --get --data-urlencode "query=$1" \
        -H "Authorization: Bearer ${PROM_TOKEN}" \
        "${THANOS_URL}/api/v1/query"
}

echo "Waiting ${SCRAPE_SETTLE_SECONDS}s for the hosted control plane targets to be scraped"
sleep "${SCRAPE_SETTLE_SECONDS}"

series_count="$(promq "count(etcd_server_has_leader{namespace=\"${HCP_NAMESPACE}\"})" \
    | jq -r '.data.result[0].value[1] // "0"')"
if [[ "${series_count}" == "0" ]]; then
    echo "FATAL: Thanos returns no etcd metrics for namespace ${HCP_NAMESPACE}."
    echo "Without them this run would produce a workload but no measurement, so fail now"
    echo "rather than burn the cluster time. Check that the hosted control plane's etcd"
    echo "ServiceMonitors exist and that user workload monitoring came up."
    mc get servicemonitor -n "${HCP_NAMESPACE}" 2>&1 | head -20 || true
    exit 1
fi
echo "Scraping ${series_count} etcd member(s) in ${HCP_NAMESPACE}"

# ---------------------------------------------------------------------------
# Metrics profile
#
# This is the upstream kube-burner-ocp etcd-density profile re-scoped for a
# hosted control plane: every series is confined to ${HCP_NAMESPACE} on the
# management cluster instead of openshift-etcd, and the etcd series keep their
# pod label so each shard is reported on its own. The metric set is the one the
# perf and scale team characterised standard vs sharded with.
# ---------------------------------------------------------------------------
PROFILE=/tmp/hcp-etcd-density-metrics.yml
cat > "${PROFILE}" <<EOF
# etcd database size and fragmentation
- query: avg by (pod) (etcd_mvcc_db_total_size_in_bytes{namespace="${HCP_NAMESPACE}"})
  metricName: etcdDBTotalSize
- query: avg by (pod) (etcd_mvcc_db_total_size_in_use_in_bytes{namespace="${HCP_NAMESPACE}"})
  metricName: etcdDBSizeInUse
- query: avg by (pod) (etcd_mvcc_db_total_size_in_bytes{namespace="${HCP_NAMESPACE}"}) - avg by (pod) (etcd_mvcc_db_total_size_in_use_in_bytes{namespace="${HCP_NAMESPACE}"})
  metricName: etcdDBFragmentationBytes
- query: (etcd_mvcc_db_total_size_in_bytes{namespace="${HCP_NAMESPACE}"} / etcd_server_quota_backend_bytes{namespace="${HCP_NAMESPACE}"}) * 100
  metricName: etcdDBSpaceUsed

# Write path latency
- query: histogram_quantile(0.99, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket{namespace="${HCP_NAMESPACE}"}[2m])) by (pod, le))
  metricName: 99thEtcdDiskWalFsyncDurationSeconds
- query: histogram_quantile(0.99, sum(rate(etcd_disk_backend_commit_duration_seconds_bucket{namespace="${HCP_NAMESPACE}"}[2m])) by (pod, le))
  metricName: 99thEtcdDiskBackendCommitDurationSeconds
- query: irate(etcd_disk_wal_fsync_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdDiskWalFsyncSum
- query: etcd_disk_wal_fsync_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}
  metricName: etcdDiskWalFsyncDurationTotal
- query: irate(etcd_disk_wal_fsync_duration_seconds_count{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdDiskWalFsyncCount
- query: etcd_disk_wal_fsync_duration_seconds_count{namespace="${HCP_NAMESPACE}"}
  metricName: etcdDiskWalFsyncCountTotal
- query: irate(etcd_disk_backend_commit_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdDiskBackendCommitSum
- query: etcd_disk_backend_commit_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}
  metricName: etcdDiskBackendCommitDurationTotal
- query: irate(etcd_disk_backend_commit_duration_seconds_count{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdDiskBackendCommitCount
- query: etcd_disk_backend_commit_duration_seconds_count{namespace="${HCP_NAMESPACE}"}
  metricName: etcdDiskBackendCommitCountTotal

# Compaction, defrag and snapshots. db-quota-pressure was the one workload where
# sharding lost to the standard offering on compaction cost, so these matter.
- query: delta(etcd_debugging_mvcc_db_compaction_total_duration_milliseconds_sum{namespace="${HCP_NAMESPACE}"}[1m:30s])/2 > 0
  metricName: etcdCompaction
- query: etcd_debugging_mvcc_db_compaction_total_duration_milliseconds_sum{namespace="${HCP_NAMESPACE}"}
  metricName: etcdCompactionDurationTotal
- query: delta(etcd_disk_backend_defrag_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}[1m:30s])/2 > 0
  metricName: etcdDefrag
- query: sum by (pod) (rate(etcd_debugging_snap_save_total_duration_seconds_sum{namespace="${HCP_NAMESPACE}"}[2m]))
  metricName: etcdSnapshotDuration

# Raft
- query: sum by (pod) (rate(etcd_server_proposals_committed_total{namespace="${HCP_NAMESPACE}"}[2m]))
  metricName: etcdProposalsCommittedRate
- query: sum by (pod) (rate(etcd_server_proposals_applied_total{namespace="${HCP_NAMESPACE}"}[2m]))
  metricName: etcdProposalsAppliedRate
- query: sum by (pod) (rate(etcd_server_proposals_failed_total{namespace="${HCP_NAMESPACE}"}[2m]))
  metricName: etcdProposalsFailedRate
- query: sum by (pod) (etcd_server_proposals_pending{namespace="${HCP_NAMESPACE}"})
  metricName: etcdProposalsPending
- query: sum by (pod) (rate(etcd_server_leader_changes_seen_total{namespace="${HCP_NAMESPACE}"}[2m]))
  metricName: etcdLeaderChangesRate
- query: max by (pod) (etcd_server_has_leader{namespace="${HCP_NAMESPACE}"})
  metricName: etcdHasLeader

# Slow operations
- query: delta(etcd_server_slow_apply_total{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdSlowApply
- query: delta(etcd_server_slow_read_indexes_total{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdSlowReadIndexes

# Key space. With sharding this splits across pods, which is the whole point.
- query: etcd_debugging_mvcc_keys_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdKeys
- query: etcd_debugging_mvcc_db_compaction_keys_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdCompactedKeys
- query: rate(etcd_mvcc_put_total{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdPutRate
- query: rate(etcd_mvcc_delete_total{namespace="${HCP_NAMESPACE}"}[2m])
  metricName: etcdDeleteRate

# Container resources. Sharding buys latency at the cost of running more etcd
# members, and the measured memory overhead was large, so track it per pod.
- query: (sum(irate(container_cpu_usage_seconds_total{namespace="${HCP_NAMESPACE}", container="etcd"}[2m]) * 100) by (pod)) > 0
  metricName: containerCPU
- query: sum(container_memory_working_set_bytes{namespace="${HCP_NAMESPACE}", container="etcd"}) by (pod)
  metricName: containerMemory
- query: sum(container_memory_working_set_bytes{namespace="${HCP_NAMESPACE}"}) by (pod, container)
  metricName: hcpContainerMemory

# Management cluster node pressure. Not filtered to the nodes hosting this
# control plane: the node list is written to the artifact directory separately
# so the series can be narrowed during analysis.
- query: rate(node_vmstat_pgmajfault[2m])
  metricName: nodeMajorPageFaults

# Hosted kube-apiserver. This is what the guest cluster actually feels when
# etcd slows down, and it is the number a shard routing change should move.
- query: histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{namespace="${HCP_NAMESPACE}", subresource!="log", verb!~"WATCH|WATCHLIST|PROXY"}[2m])) by (verb, le))
  metricName: requestDuration99thByVerb
- query: histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{namespace="${HCP_NAMESPACE}", subresource!="log", verb!~"WATCH|WATCHLIST|PROXY"}[2m])) by (resource, le))
  metricName: requestDuration99thByResource
- query: sum(rate(apiserver_request_total{namespace="${HCP_NAMESPACE}", verb!="WATCH"}[2m])) by (verb, resource, code) > 0
  metricName: APIRequestRate
- query: sum(apiserver_current_inflight_requests{namespace="${HCP_NAMESPACE}"}) by (request_kind)
  metricName: requestInFlight
- query: sum(rate(apiserver_request_terminations_total{namespace="${HCP_NAMESPACE}"}[2m])) by (verb)
  metricName: requestRateDropped
- query: topk(20, max by (resource) (apiserver_storage_objects{namespace="${HCP_NAMESPACE}"}))
  metricName: etcdStorageObjects

# Start and end snapshots
- query: etcd_mvcc_db_total_size_in_bytes{namespace="${HCP_NAMESPACE}"}
  metricName: etcdDBTotalSizeSnapshot
  instant: true
  captureStart: true
- query: etcd_debugging_mvcc_keys_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdKeysSnapshot
  instant: true
  captureStart: true
- query: etcd_server_proposals_committed_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdProposalsCommitted
  instant: true
  captureStart: true
- query: etcd_server_slow_apply_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdSlowApplyTotal
  instant: true
  captureStart: true
- query: etcd_server_leader_changes_seen_total{namespace="${HCP_NAMESPACE}"}
  metricName: etcdLeaderChanges
  instant: true
  captureStart: true
- query: etcd_debugging_mvcc_db_compaction_total_duration_milliseconds_sum{namespace="${HCP_NAMESPACE}"}
  metricName: etcdCompaction-raw
  instant: true
  captureStart: true
- query: sum(container_memory_working_set_bytes{namespace="${HCP_NAMESPACE}", container="etcd"}) by (pod)
  metricName: containerMemorySnapshot
  instant: true
  captureStart: true
EOF
cp "${PROFILE}" "${ARTIFACT_DIR}/hcp-etcd-density-metrics.yml"

# Nodes of the management cluster that are actually hosting this control plane,
# for narrowing the unfiltered node level series during analysis.
mc get pods -n "${HCP_NAMESPACE}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sort -u | grep -v '^$' > "${ARTIFACT_DIR}/hcp-management-nodes.txt" || true

# ---------------------------------------------------------------------------
# Metrics endpoints
#
# An endpoint with no indexer collects nothing that survives the run, so there
# is always a "local" one writing files that end up in the artifact directory.
# Indexing to Elasticsearch, when asked for, is a second endpoint over the same
# Thanos rather than a replacement, so a run is always inspectable by hand even
# when Orion is also getting the data.
#
# This file lives in /tmp and is never copied to ARTIFACT_DIR: it embeds the
# bearer token and, when indexing is on, the Elasticsearch credentials.
# ---------------------------------------------------------------------------
UUID="$(uuidgen)"
METRICS_DIR="/tmp/collected-metrics-${UUID}"
ENDPOINT_FILE=/tmp/metrics-endpoint.yml
{
    echo "- endpoint: ${THANOS_URL}"
    echo "  token: ${PROM_TOKEN}"
    echo "  skipTLSVerify: true"
    echo "  step: ${METRICS_STEP}"
    echo "  metrics:"
    echo "  - ${PROFILE}"
    echo "  indexer:"
    echo "    type: local"
    echo "    metricsDirectory: ${METRICS_DIR}"
} > "${ENDPOINT_FILE}"

if [[ "${INDEX_TO_ES}" == "true" ]]; then
    ES_HOST="search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    if [[ -e "${ES_SECRETS_PATH}/host" ]]; then
        ES_HOST="$(cat "${ES_SECRETS_PATH}/host")"
    fi
    ES_USERNAME="$(cat "${ES_SECRETS_PATH}/username")"
    ES_PASSWORD="$(cat "${ES_SECRETS_PATH}/password")"
    {
        echo "- endpoint: ${THANOS_URL}"
        echo "  token: ${PROM_TOKEN}"
        echo "  skipTLSVerify: true"
        echo "  step: ${METRICS_STEP}"
        echo "  metrics:"
        echo "  - ${PROFILE}"
        echo "  indexer:"
        echo "    type: opensearch"
        echo "    esServers: [\"https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}\"]"
        echo "    defaultIndex: ${ES_INDEX}"
        echo "    insecureSkipVerify: true"
    } >> "${ENDPOINT_FILE}"
    echo "Results will also be indexed to Elasticsearch under uuid ${UUID}"
else
    echo "INDEX_TO_ES is false; results stay in the artifact directory only"
fi

# Metadata that makes a result set identifiable after the fact. Consumed by
# kube-burner as extra document fields, and kept as an artifact either way.
cat > /tmp/user-metadata.yaml <<EOF
platform: hypershift
shardingVariant: ${ETCD_PERF_VARIANT}
etcdWorkload: ${ETCD_PERF_WORKLOAD}
hostedClusterName: ${CLUSTER_NAME}
hcpNamespace: ${HCP_NAMESPACE}
prowJobId: ${PROW_JOB_ID:-unknown}
EOF
cp /tmp/user-metadata.yaml "${ARTIFACT_DIR}/user-metadata.yaml"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if [[ -z "${KUBE_BURNER_URL}" ]]; then
    KUBE_BURNER_URL="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_VERSION}/kube-burner-ocp-V${KUBE_BURNER_VERSION}-$(uname -s)-$(uname -m).tar.gz"
fi
echo "Downloading kube-burner-ocp from ${KUBE_BURNER_URL}"
curl --fail --retry 8 --retry-all-errors -sS -L "${KUBE_BURNER_URL}" | tar -xzC /tmp/ kube-burner-ocp
chmod +x /tmp/kube-burner-ocp

# The workload targets the guest API server; the metrics come from the
# management cluster via the endpoint file above.
export KUBECONFIG="${GUEST_KUBECONFIG}"

cd /tmp
COMMAND=(
    /tmp/kube-burner-ocp etcd-density "${ETCD_PERF_WORKLOAD}"
    --uuid="${UUID}"
    --qps="${QPS}"
    --burst="${BURST}"
    --gc="${GC}"
    --log-level=info
    --user-metadata=/tmp/user-metadata.yaml
    --metrics-endpoint="${ENDPOINT_FILE}"
)
if [[ -n "${ETCD_PERF_FLAGS}" ]]; then
    # Word splitting is the point here: ETCD_PERF_FLAGS is a flag list. None of
    # the etcd-density flags take a value containing whitespace.
    # shellcheck disable=SC2206
    COMMAND+=(${ETCD_PERF_FLAGS})
fi

echo "Running: ${COMMAND[*]}"
set +e
"${COMMAND[@]}"
RUN_EXIT_CODE=$?
set -e
echo "kube-burner-ocp exited with ${RUN_EXIT_CODE}"

if [[ -d "${METRICS_DIR}" ]]; then
    cp -r "${METRICS_DIR}" "${ARTIFACT_DIR}/"
else
    echo "WARNING: ${METRICS_DIR} was never created, so no metrics were collected."
fi

# ---------------------------------------------------------------------------
# Gates
#
# Deliberately coarse. Run over run regression detection belongs in Orion over
# the indexed metrics; these only exist so that a grossly degraded run fails
# the job instead of quietly publishing bad numbers.
# ---------------------------------------------------------------------------
FAILURES=()

if [[ -n "${ETCD_MAX_P99_COMMIT_LATENCY_MS}" ]]; then
    peak_s="$(promq "max_over_time(histogram_quantile(0.99, sum(rate(etcd_disk_backend_commit_duration_seconds_bucket{namespace=\"${HCP_NAMESPACE}\"}[2m])) by (le))[2h:1m])" \
        | jq -r '.data.result[0].value[1] // "0"')"
    peak_ms="$(awk -v v="${peak_s}" 'BEGIN{printf "%.2f", v * 1000}')"
    echo "Peak p99 etcd backend commit latency: ${peak_ms}ms (limit ${ETCD_MAX_P99_COMMIT_LATENCY_MS}ms)"
    if awk -v a="${peak_ms}" -v b="${ETCD_MAX_P99_COMMIT_LATENCY_MS}" 'BEGIN{exit !(a > b)}'; then
        FAILURES+=("peak p99 etcd backend commit latency was ${peak_ms}ms, above the ${ETCD_MAX_P99_COMMIT_LATENCY_MS}ms limit")
    fi
fi

if [[ -n "${ETCD_MAX_LEADER_CHANGES}" ]]; then
    changes="$(promq "max(increase(etcd_server_leader_changes_seen_total{namespace=\"${HCP_NAMESPACE}\"}[2h]))" \
        | jq -r '.data.result[0].value[1] // "0"')"
    printf 'etcd leader changes during the run: %.0f (limit %s)\n' "${changes}" "${ETCD_MAX_LEADER_CHANGES}"
    if awk -v a="${changes}" -v b="${ETCD_MAX_LEADER_CHANGES}" 'BEGIN{exit !(a > b)}'; then
        FAILURES+=("etcd saw ${changes} leader changes, above the ${ETCD_MAX_LEADER_CHANGES} limit")
    fi
fi

TESTCASE_NAME="etcd-density ${ETCD_PERF_WORKLOAD} (${ETCD_PERF_VARIANT})"
JUNIT="${ARTIFACT_DIR}/junit_hypershift_etcd_perf.xml"
if [[ ${RUN_EXIT_CODE} -ne 0 ]]; then
    FAILURES+=("kube-burner-ocp exited with ${RUN_EXIT_CODE}")
fi

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    cat > "${JUNIT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift etcd perf" tests="1" failures="0">
  <testcase name="${TESTCASE_NAME}"/>
</testsuite>
EOF
    exit 0
fi

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuite name="hypershift etcd perf" tests="1" failures="1">'
    echo "  <testcase name=\"${TESTCASE_NAME}\">"
    echo '    <failure message="etcd performance run did not meet its bounds"><![CDATA['
    printf '%s\n' "${FAILURES[@]}"
    echo ']]></failure>'
    echo '  </testcase>'
    echo '</testsuite>'
} > "${JUNIT}"

printf 'FAILED: %s\n' "${FAILURES[@]}"
exit 1
