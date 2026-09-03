#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/proxy-conf.sh"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

namespace=ovs-veth-filter
checkout=/tmp/ovs-veth-filter-release
assets="${checkout}/hack/ovs-veth-netlink-filter"

rm -rf "${checkout}"
git clone --depth 1 --branch "${OVS_VETH_FILTER_REF}" \
    "${OVS_VETH_FILTER_REPO}" "${checkout}"

oc create namespace "${namespace}" --dry-run=client -o yaml | oc apply -f -
oc label namespace "${namespace}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite
oc create serviceaccount ovs-veth-filter -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user privileged \
    -z ovs-veth-filter -n "${namespace}"

if ! oc get buildconfig ovs-veth-filter -n "${namespace}" >/dev/null 2>&1; then
    oc new-build --name=ovs-veth-filter --binary --strategy=docker \
        -n "${namespace}"
fi
oc start-build ovs-veth-filter --from-dir="${assets}" --follow --wait \
    -n "${namespace}"
oc apply -f "${assets}/daemonset.yaml"
image=$(oc get imagestreamtag ovs-veth-filter:latest -n "${namespace}" \
    -o jsonpath='{.image.dockerImageReference}')
oc set image daemonset/ovs-veth-filter "filter=${image}" -n "${namespace}"
oc rollout status daemonset/ovs-veth-filter -n "${namespace}" --timeout=20m

desired=$(oc get daemonset ovs-veth-filter -n "${namespace}" \
    -o jsonpath='{.status.desiredNumberScheduled}')
ready=$(oc get daemonset ovs-veth-filter -n "${namespace}" \
    -o jsonpath='{.status.numberReady}')
if [[ "${desired}" == 0 || "${ready}" != "${desired}" ]]; then
    echo "BPF filter DaemonSet is not ready: ${ready}/${desired}" >&2
    exit 1
fi

sleep "${OVS_VETH_FILTER_SETTLE_SECONDS}"

for pod in $(oc get pods -n "${namespace}" -l app=ovs-veth-filter \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if ! oc logs -n "${namespace}" "${pod}" | \
        grep -q 'filtering veth link events for OVS netlink port ID'; then
        echo "BPF filter did not attach to the OVS route socket in ${pod}" >&2
        oc logs -n "${namespace}" "${pod}" >&2 || true
        exit 1
    fi
done

baseline_dir="${SHARED_DIR}/ovs-veth-filter-baseline"
mkdir -p "${baseline_dir}"
for pod in $(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node=$(oc get pod -n openshift-ovn-kubernetes "${pod}" \
        -o jsonpath='{.spec.nodeName}')
    oc exec -n openshift-ovn-kubernetes "${pod}" -c ovn-controller -- \
        ovs-appctl -t ovs-vswitchd coverage/show \
        > "${baseline_dir}/ovs-coverage-${node}.txt"
done

oc get pods -n "${namespace}" -o wide
oc wait pod -n "${namespace}" -l app=ovs-veth-filter \
    --for=condition=Ready --timeout=2m
