#!/bin/bash
set +e

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

namespace=ovs-veth-filter
mkdir -p "${ARTIFACT_DIR}"
echo "Copying pre-workload OVS coverage baselines to ${ARTIFACT_DIR}"
baseline_count=0
for baseline in "${SHARED_DIR}"/ovs-coverage-baseline-*.txt; do
    [[ -e "${baseline}" ]] || continue
    if cp "${baseline}" "${ARTIFACT_DIR}/"; then
        baseline_count=$((baseline_count + 1))
    else
        echo "Failed to copy OVS baseline ${baseline}" >&2
    fi
done
echo "Copied ${baseline_count} OVS coverage baseline files"
if [[ -f "${SHARED_DIR}/ovs-perf-profile-nodes.txt" ]]; then
    cp "${SHARED_DIR}/ovs-perf-profile-nodes.txt" "${ARTIFACT_DIR}/"
fi

oc get daemonset,pods,build,buildconfig -n "${namespace}" -o wide \
    > "${ARTIFACT_DIR}/ovs-veth-filter-resources.txt" 2>&1
oc get daemonset ovs-veth-filter -n "${namespace}" -o yaml \
    > "${ARTIFACT_DIR}/ovs-veth-filter-daemonset.yaml" 2>&1
oc logs daemonset/ovs-veth-filter -n "${namespace}" --all-containers=true --prefix \
    > "${ARTIFACT_DIR}/ovs-veth-filter.log" 2>&1
oc get clusteroperator network -o yaml \
    > "${ARTIFACT_DIR}/network-clusteroperator.yaml" 2>&1

for pod in $(oc get pods -n "${namespace}" -l app=ovs-veth-filter \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node=$(oc get pod -n "${namespace}" "${pod}" \
        -o jsonpath='{.spec.nodeName}')
    oc exec -n "${namespace}" "${pod}" -c filter -- \
        bpftool -j map dump pinned /sys/fs/bpf/ovs_veth_netlink_filter/maps/stats \
        > "${ARTIFACT_DIR}/bpf-stats-${node}.json" 2>&1

    if [[ ! -f "${SHARED_DIR}/ovs-perf-profile-nodes.txt" ]] || \
       ! grep -Fxq "${node}" "${SHARED_DIR}/ovs-perf-profile-nodes.txt"; then
        continue
    fi

    # A failed workload can enter post steps before the bounded recording ends.
    # Interrupt perf and wait for its parent script to finalize perf.data.
    oc exec -n "${namespace}" "${pod}" -c profiler -- bash -c '
        pid_file=/run/ovs-veth-filter/perf.pid
        if [[ -s $pid_file ]]; then
            touch /run/ovs-veth-filter/perf.stop-requested
            kill -INT "$(cat "$pid_file")" 2>/dev/null || true
            for _ in $(seq 1 60); do
                [[ ! -e $pid_file ]] && exit 0
                sleep 1
            done
            echo "timed out waiting for perf to finalize" >&2
            exit 1
        fi
    ' || echo "Could not stop an active perf recording on ${node}" >&2

    remote_dir=/var/tmp/ovs-veth-filter-perf
    echo "Rendering timestamped perf chunks from ${node}"
    oc exec -n "${namespace}" "${pod}" -c profiler -- bash -c '
        set -o pipefail
        node=$1
        remote_dir=/var/tmp/ovs-veth-filter-perf
        ovs_pid=$(pidof ovs-vswitchd 2>/dev/null | awk "{ print \$1 }")
        failed=0
        found=0
        while IFS= read -r -d "" data_file; do
            found=1
            echo "Rendering $(basename "$data_file")"
            perf report --stdio --no-children --call-graph none \
                --sort comm,dso,symbol --percent-limit 0.1 \
                --symfs "/proc/${ovs_pid}/root" --kallsyms /proc/kallsyms \
                -i "$data_file" > "${data_file}.report.txt" 2>&1 || failed=1
            perf script --symfs "/proc/${ovs_pid}/root" \
                --kallsyms /proc/kallsyms -i "$data_file" 2>/dev/null \
                | gzip -1 > "${data_file}.script.txt.gz" || failed=1
        done < <(find "$remote_dir" -maxdepth 1 -type f \
            \( -name "ovs-perf-${node}-*.data" \
            -o -name "ovs-perf-${node}-*.data.*" \) \
            ! -name "*.report.txt" ! -name "*.script.txt.gz" \
            -print0 | sort -z)
        if ((found == 0)); then
            echo "No perf data chunks found for ${node}" >&2
            exit 1
        fi
        exit "$failed"
    ' -- "${node}" || \
        echo "Failed to render one or more perf views for ${node}" >&2

    artifact_node_dir=${ARTIFACT_DIR}/ovs-perf-${node}
    mkdir -p "${artifact_node_dir}"
    echo "Collecting all perf chunks from ${node} into ${artifact_node_dir}"
    oc cp -n "${namespace}" -c profiler \
        "${pod}:${remote_dir}/." "${artifact_node_dir}/" || \
        echo "Failed to copy perf artifacts from ${node}" >&2
done

for pod in $(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node=$(oc get pod -n openshift-ovn-kubernetes "${pod}" \
        -o jsonpath='{.spec.nodeName}')
    oc exec -n openshift-ovn-kubernetes "${pod}" -c ovn-controller -- \
        ovs-appctl -t ovs-vswitchd coverage/show \
        > "${ARTIFACT_DIR}/ovs-coverage-${node}.txt" 2>&1
done

if [[ "${OVS_VETH_FILTER_CLEANUP}" == true ]] && \
   oc get namespace "${namespace}" >/dev/null 2>&1; then
    cleanup_status=0
    oc delete daemonset ovs-veth-filter -n "${namespace}" \
        --ignore-not-found --wait=true --timeout=5m || cleanup_status=1
    oc delete namespace "${namespace}" --ignore-not-found --wait=false || \
        cleanup_status=1
    if ((cleanup_status)); then
        echo "failed to remove one or more privileged BPF resources" >&2
        exit 1
    fi
fi
exit 0
