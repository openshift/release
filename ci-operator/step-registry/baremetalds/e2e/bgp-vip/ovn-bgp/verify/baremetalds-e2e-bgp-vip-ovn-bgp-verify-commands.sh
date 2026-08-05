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

CLI="podman"
if ! command -v podman &>/dev/null; then
    CLI="docker"
fi

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

# poll <deadline-seconds> <function> — re-evaluate until success or timeout,
# allowing normal CR/BGP reconciliation to converge before asserting state
poll() {
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 10
    done
}

nodes="$(oc get nodes -o name | wc -l)"

echo "[1/4] both BGP consumers own FRRConfiguration CRs in openshift-frr-k8s"
check_crs() {
    oc get frrconfiguration -n openshift-frr-k8s bgp-vip receive-filtered &>/dev/null
}
if ! poll 120 check_crs; then
    oc get frrconfiguration -n openshift-frr-k8s || true
    fail "FRRConfigurations 'bgp-vip' and 'receive-filtered' not both present in openshift-frr-k8s"
fi

echo "[2/4] every node has an Established BGP session to the route reflector"
# The route reflector (external 'frr' container, 192.168.111.3) peers with
# every node. On the control plane the RouteAdvertisements-generated
# FRRConfiguration must be merged by the frr-k8s *static pods* (the frr-k8s
# DaemonSet does not run there), so established master sessions prove the
# static-pod CR merge works alongside the VIP configuration.
check_sessions() {
    local established
    established="$(${CLI} exec frr vtysh -c 'show bgp ipv4 unicast summary json' \
        | jq '[.peers[] | select(.state=="Established")] | length')"
    [[ "${established:-0}" -eq "${nodes}" ]]
}
if ! poll 300 check_sessions; then
    ${CLI} exec frr vtysh -c 'show bgp ipv4 unicast summary' || true
    fail "route reflector does not have ${nodes} Established sessions (one per node)"
fi

echo "[3/4] every node's pod subnet is advertised to the route reflector"
# assert the exact per-node OVN subnets, not a route count: the reflector's
# table also carries unrelated prefixes (e.g. the agnhost network)
check_pod_subnets() {
    local rr_routes subnet missing=0
    rr_routes="$(${CLI} exec frr vtysh -c 'show bgp ipv4 unicast json' | jq -r '.routes | keys[]')"
    for subnet in $(oc get nodes -o jsonpath='{.items[*].metadata.annotations.k8s\.ovn\.org/node-subnets}' \
        | jq -r -s '.[].default[]' | grep -F . ); do
        if ! grep -qx "${subnet}" <<< "${rr_routes}"; then
            echo "pod subnet ${subnet} not (yet) at the route reflector"
            missing=1
        fi
    done
    [[ "${missing}" -eq 0 ]]
}
if ! poll 300 check_pod_subnets; then
    ${CLI} exec frr vtysh -c 'show bgp ipv4 unicast' || true
    fail "not every node's pod subnet is advertised to the route reflector"
fi

echo "[4/4] pod-network datapath over BGP: pod reaches the external agnhost"
# 172.20.0.100 lives behind the route reflector (agnhost macvlan network);
# the cluster imports it via the receive-filtered FRRConfiguration. A pod
# reaching it proves the RA datapath works on a BGP-VIP-managed cluster.
oc delete pod bgp-ra-datapath-check --ignore-not-found
if oc run bgp-ra-datapath-check --restart=Never --attach --rm --pod-running-timeout=5m \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --command -- \
    curl --max-time 20 -s --fail --show-error http://172.20.0.100:8000/hostname; then
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
