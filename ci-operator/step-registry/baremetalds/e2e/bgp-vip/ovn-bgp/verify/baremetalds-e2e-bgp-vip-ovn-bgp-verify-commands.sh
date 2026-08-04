#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip ovn-bgp coexistence verify command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << 'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

nodes="$(oc get nodes -o name | wc -l)"

echo "[1/4] both BGP consumers own FRRConfiguration CRs in openshift-frr-k8s"
for cr in bgp-vip receive-filtered; do
    if ! oc get frrconfiguration -n openshift-frr-k8s "${cr}" &>/dev/null; then
        fail "FRRConfiguration '${cr}' not found in openshift-frr-k8s"
    fi
done

echo "[2/4] every node has an Established BGP session to the route reflector"
# The route reflector (external 'frr' container, 192.168.111.3) peers with
# every node. On the control plane the RouteAdvertisements-generated
# FRRConfiguration must be merged by the frr-k8s *static pods* (the frr-k8s
# DaemonSet does not run there), so established master sessions prove the
# static-pod CR merge works alongside the VIP configuration.
established="$(podman exec frr vtysh -c 'show bgp ipv4 unicast summary json' \
    | jq '[.peers[] | select(.state=="Established")] | length')"
if [[ "${established:-0}" -ne "${nodes}" ]]; then
    podman exec frr vtysh -c 'show bgp ipv4 unicast summary'
    fail "route reflector has ${established:-0} Established session(s), expected ${nodes} (one per node)"
fi

echo "[3/4] every node's pod subnet is advertised to the route reflector"
cluster_network="$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[0].cidr}')"
pod_routes="$(podman exec frr vtysh -c "show bgp ipv4 unicast json" \
    | jq --arg net "${cluster_network}" '[.routes | keys[] | select(. != $net)] | length')"
# each node advertises its own host subnet out of the cluster network
if [[ "${pod_routes:-0}" -lt "${nodes}" ]]; then
    podman exec frr vtysh -c 'show bgp ipv4 unicast'
    fail "route reflector sees ${pod_routes:-0} pod subnet route(s), expected at least ${nodes}"
fi

echo "[4/4] pod-network datapath over BGP: pod reaches the external agnhost"
# 172.20.0.100 lives behind the route reflector (agnhost macvlan network);
# the cluster imports it via the receive-filtered FRRConfiguration. A pod
# reaching it proves the RA datapath works on a BGP-VIP-managed cluster.
oc delete pod bgp-ra-datapath-check --ignore-not-found
if oc run bgp-ra-datapath-check --restart=Never --attach --rm --pod-running-timeout=5m \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --command -- \
    curl --max-time 20 -s http://172.20.0.100:8000/hostname; then
    echo "agnhost reachable from pod network"
else
    fail "pod could not reach agnhost 172.20.0.100:8000 over the BGP-imported route"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + OVN-K route advertisements coexistence verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + OVN-K route advertisements coexistence verification passed"
EOF
