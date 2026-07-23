#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

set -x

REPORT="${ARTIFACT_DIR}/ovn-libovsdb-check.log"
FAILURES=0

collect() {
    local label="$1"; shift
    echo "=== ${label} ==="
    if ! "$@" 2>/dev/null; then
        echo "(not available)"
        FAILURES=$((FAILURES + 1))
    fi
    echo ""
}

{
    echo "========================================"
    echo "OCPBUGS-98252 Pre-check: OVN libovsdb migration"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""

    collect "Cluster Version" \
        oc get clusterversion version -o jsonpath='{.status.desired.version}'
    echo ""

    collect "OVN-K Image" \
        oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
        -o jsonpath='{.items[0].spec.containers[?(@.name=="ovnkube-controller")].image}'
    echo ""

    collect "Worker Node Count" \
        oc get nodes -l node-role.kubernetes.io/worker= --no-headers

    collect "Worker Node Resources" \
        oc adm top nodes -l node-role.kubernetes.io/worker=

    echo "=== Pre-test ovnkube-controller CPU ==="
    oc adm top pods -n openshift-ovn-kubernetes -l app=ovnkube-node --containers 2>/dev/null \
        | grep ovnkube-controller || echo "(metrics not available yet)"
    echo ""

    echo "=== Check for ovs-vsctl in CNI path (should be minimal with fix) ==="
    OVN_POD=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${OVN_POD}" ]; then
        echo "Checking ovnkube-controller container for ovs-vsctl usage patterns..."
        oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c ovnkube-controller \
            -- strings /usr/bin/ovnkube 2>/dev/null | grep -c "ovs-vsctl" || true
        echo ""
        echo "=== Pre-test ovnkube-controller logs (last 60s) ==="
        oc logs -n openshift-ovn-kubernetes "${OVN_POD}" -c ovnkube-controller \
            --since=60s 2>/dev/null | tail -50 || true
    fi
    echo ""

    echo "=== ovs-vsctl process baseline (all workers) ==="
    for WORKER in $(oc get nodes -l node-role.kubernetes.io/worker= \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        OVS_COUNT=$(oc debug "node/${WORKER}" -- chroot /host pgrep -c ovs-vsctl 2>/dev/null || true)
        echo "  ${WORKER}: ovs-vsctl processes = ${OVS_COUNT:-0}"
    done
    echo ""

    echo "========================================"
    echo "Pre-check complete (${FAILURES} probe(s) unavailable)"
    echo "========================================"
} 2>&1 | tee "${REPORT}"
