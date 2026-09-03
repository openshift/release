#!/bin/bash
set +e

source "${SHARED_DIR}/proxy-conf.sh"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

namespace=ovs-veth-filter
mkdir -p "${ARTIFACT_DIR}"
cp -a "${SHARED_DIR}/ovs-veth-filter-baseline" \
    "${ARTIFACT_DIR}/" 2>/dev/null

oc get daemonset,pods,build,buildconfig -n "${namespace}" -o wide \
    > "${ARTIFACT_DIR}/ovs-veth-filter-resources.txt" 2>&1
oc get daemonset ovs-veth-filter -n "${namespace}" -o yaml \
    > "${ARTIFACT_DIR}/ovs-veth-filter-daemonset.yaml" 2>&1
oc logs daemonset/ovs-veth-filter -n "${namespace}" --prefix \
    > "${ARTIFACT_DIR}/ovs-veth-filter.log" 2>&1
oc get clusteroperator network -o yaml \
    > "${ARTIFACT_DIR}/network-clusteroperator.yaml" 2>&1

for pod in $(oc get pods -n "${namespace}" -l app=ovs-veth-filter \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node=$(oc get pod -n "${namespace}" "${pod}" \
        -o jsonpath='{.spec.nodeName}')
    oc exec -n "${namespace}" "${pod}" -- \
        bpftool -j map dump pinned /sys/fs/bpf/ovs_veth_netlink_filter/maps/stats \
        > "${ARTIFACT_DIR}/bpf-stats-${node}.json" 2>&1
done

for pod in $(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node=$(oc get pod -n openshift-ovn-kubernetes "${pod}" \
        -o jsonpath='{.spec.nodeName}')
    oc exec -n openshift-ovn-kubernetes "${pod}" -c ovn-controller -- \
        ovs-appctl -t ovs-vswitchd coverage/show \
        > "${ARTIFACT_DIR}/ovs-coverage-${node}.txt" 2>&1
done

oc delete daemonset ovs-veth-filter -n "${namespace}" \
    --ignore-not-found --wait=true --timeout=5m
oc adm policy remove-scc-from-user privileged \
    -z ovs-veth-filter -n "${namespace}"
oc delete namespace "${namespace}" --ignore-not-found --wait=false
exit 0
