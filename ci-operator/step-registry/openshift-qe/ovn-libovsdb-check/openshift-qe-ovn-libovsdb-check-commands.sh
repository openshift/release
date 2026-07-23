#!/bin/bash
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

REPORT="${ARTIFACT_DIR}/ovn-libovsdb-check.log"

{
    echo "========================================"
    echo "OCPBUGS-98252 Pre-check: OVN libovsdb migration"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""

    echo "=== Cluster Version ==="
    oc get clusterversion version -o jsonpath='{.status.desired.version}'
    echo ""
    echo ""

    echo "=== OVN-K Image ==="
    oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].spec.containers[?(@.name=="ovnkube-controller")].image}' 2>/dev/null
    echo ""
    echo ""

    echo "=== Worker Node Count ==="
    oc get nodes -l node-role.kubernetes.io/worker= --no-headers | wc -l
    echo ""

    echo "=== Worker Node Resources ==="
    oc adm top nodes -l node-role.kubernetes.io/worker= 2>/dev/null || echo "(metrics not available yet)"
    echo ""

    echo "=== Pre-test ovnkube-controller CPU ==="
    oc adm top pods -n openshift-ovn-kubernetes -l app=ovnkube-node --containers 2>/dev/null | grep ovnkube-controller || echo "(metrics not available yet)"
    echo ""

    echo "=== Check for ovs-vsctl in CNI path (should be minimal with fix) ==="
    OVN_POD=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "${OVN_POD}" ]; then
        echo "Checking ovnkube-controller container for ovs-vsctl usage patterns..."
        oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c ovnkube-controller -- strings /usr/bin/ovnkube 2>/dev/null | grep -c "ovs-vsctl" || echo "0"
        echo ""
        echo "=== Pre-test ovnkube-controller logs (last 60s) ==="
        oc logs -n openshift-ovn-kubernetes "${OVN_POD}" -c ovnkube-controller --since=60s 2>/dev/null | tail -50
    fi
    echo ""

    echo "=== ovs-vsctl process baseline ==="
    WORKER=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "${WORKER}" ]; then
        OVS_COUNT=$(oc debug "node/${WORKER}" -- chroot /host pgrep -c ovs-vsctl 2>/dev/null || echo "0")
        echo "  ${WORKER}: ovs-vsctl processes = ${OVS_COUNT}"
    fi
    echo ""

    echo "========================================"
    echo "Pre-check complete"
    echo "========================================"
} 2>&1 | tee "${REPORT}"
