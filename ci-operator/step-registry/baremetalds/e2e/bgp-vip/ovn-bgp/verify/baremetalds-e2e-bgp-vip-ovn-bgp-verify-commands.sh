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
# on dual-stack clusters every node peers with the route reflector once per
# address family, so the expected session count is one per node InternalIP
node_ips="$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | wc -w)"

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
    # count unique Established peers across both address-family summaries:
    # a v4 peer and a v6 peer from the same node are two sessions, while a
    # peer activated in both families is still one session
    local established
    established="$( { ${CLI} exec frr vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null; \
                      ${CLI} exec frr vtysh -c 'show bgp ipv6 unicast summary json' 2>/dev/null; } \
        | jq -s '[.[] | (.ipv4Unicast.peers // .ipv6Unicast.peers // .peers // {}) | to_entries[] | select(.value.state=="Established") | .key] | unique | length')"
    [[ "${established:-0}" -eq "${node_ips}" ]]
}
if ! poll 300 check_sessions; then
    ${CLI} exec frr vtysh -c 'show bgp summary' || true
    fail "route reflector does not have ${node_ips} Established sessions (one per node InternalIP, per address family)"
fi

echo "[3/4] every node's pod subnet is advertised to the route reflector"
# assert the exact per-node OVN subnets, not a route count: the reflector's
# table also carries unrelated prefixes (e.g. the agnhost network)
check_pod_subnets() {
    local all_subnets rr_routes_v4 rr_routes_v6 subnet expected missing=0
    # every node must contribute one pod subnet per cluster address family;
    # an absent or empty node-subnets annotation must fail the check, not
    # shrink the loop
    all_subnets="$(oc get nodes -o jsonpath='{.items[*].metadata.annotations.k8s\.ovn\.org/node-subnets}' \
        | { jq -r -s '.[].default[]' 2>/dev/null || true; })"
    expected="$(echo "${all_subnets}" | { grep -c . || true; })"
    families="$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[*].cidr}' | wc -w)"
    if [[ "${expected:-0}" -ne $(( nodes * families )) ]]; then
        echo "expected $(( nodes * families )) pod subnets from node annotations (${nodes} nodes x ${families} families), found ${expected:-0}"
        return 1
    fi
    rr_routes_v4="$(${CLI} exec frr vtysh -c 'show bgp ipv4 unicast json' 2>/dev/null | jq -r '.routes | keys[]')"
    rr_routes_v6="$(${CLI} exec frr vtysh -c 'show bgp ipv6 unicast json' 2>/dev/null | jq -r '.routes | keys[]')"
    for subnet in ${all_subnets}; do
        if [[ "${subnet}" == *:* ]]; then
            if ! grep -qx "${subnet}" <<< "${rr_routes_v6}"; then
                echo "pod subnet ${subnet} not (yet) at the route reflector (ipv6)"
                missing=1
            fi
        else
            if ! grep -qx "${subnet}" <<< "${rr_routes_v4}"; then
                echo "pod subnet ${subnet} not (yet) at the route reflector (ipv4)"
                missing=1
            fi
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
agnhost_targets="http://172.20.0.100:8000/hostname"
if [[ "$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[*].cidr}')" == *:* ]]; then
    # dual-stack: the agnhost container also lives at 2001:db8:2::100
    agnhost_targets="${agnhost_targets} http://[2001:db8:2::100]:8000/hostname"
fi
for target in ${agnhost_targets}; do
    oc delete pod bgp-ra-datapath-check --ignore-not-found
    if oc run bgp-ra-datapath-check --restart=Never --attach --rm --pod-running-timeout=5m \
        --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --command -- \
        curl --max-time 20 -s --fail --show-error -o /dev/null "${target}"; then
        echo "agnhost reachable from pod network via ${target}"
    else
        fail "pod could not reach agnhost ${target} over the BGP-imported route"
    fi
done

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + OVN-K route advertisements coexistence verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + OVN-K route advertisements coexistence verification passed"
EOF
