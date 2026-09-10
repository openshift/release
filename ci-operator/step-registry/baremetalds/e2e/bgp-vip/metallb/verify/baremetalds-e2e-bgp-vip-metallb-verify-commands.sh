#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip metallb coexistence verify command ************"

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

is_v6() { [[ "$1" == *:* ]]; }

echo "[1/4] MetalLB is deployed and produced FRRConfigurations in openshift-frr-k8s"
# MetalLB-generated FRRConfigurations carry no labels; select by the
# per-node name prefix 'metallb-'. grep -c returns non-zero on no match,
# so guard it with '|| true' to stay errexit/pipefail safe.
check_metallb() {
    local metallb_crs
    metallb_crs="$(oc get frrconfiguration -n openshift-frr-k8s -o name 2>/dev/null \
        | { grep -c '^frrconfiguration\.frrk8s\.metallb\.io/metallb-' || true; })"
    [[ "$(oc get deploy -n metallb-system controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ]] \
        && [[ "${metallb_crs:-0}" -ge 1 ]]
}
if ! poll 300 check_metallb; then
    oc get deploy,ds -n metallb-system || true
    oc get frrconfiguration -n openshift-frr-k8s || true
    fail "MetalLB not deployed or no MetalLB-owned FRRConfiguration in openshift-frr-k8s"
fi

echo "[2/4] same-neighbor merge: still exactly one Established ToR session per node per family"
# vtysh prints a harmless 'vtysh.conf' warning on stderr; drop stderr and
# parse stdout only so pipefail is not tripped by the noise. On dual-stack
# clusters every node holds one session per address family; MetalLB must
# merge into these, not add or flap sessions.
node_ips="$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | wc -w)"
check_sessions() {
    local established
    established="$( { ${CLI} exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null; \
                      ${CLI} exec bgp-tor vtysh -c 'show bgp ipv6 unicast summary json' 2>/dev/null; } \
        | jq -s '[.[] | (.ipv4Unicast.peers // .ipv6Unicast.peers // .peers // {}) | to_entries[] | select(.value.state=="Established") | .key] | unique | length')"
    [[ "${established:-0}" -eq "${node_ips}" ]]
}
if ! poll 300 check_sessions; then
    ${CLI} exec bgp-tor vtysh -c 'show bgp summary' || true
    fail "ToR does not have exactly ${node_ips} Established sessions (one per node InternalIP; MetalLB must merge into the existing neighbors, not add or flap sessions)"
fi

echo "[3/4] every LoadBalancer service IP is advertised to the ToR from every frr-k8s node"
# on dual-stack clusters the Service (ipFamilyPolicy: PreferDualStack) gets
# one LoadBalancer IP per family; every one must be advertised
lb_ips=""
expected_lb_ips="$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[*].cidr}' | wc -w)"
get_lb_ips() {
    lb_ips="$(oc get svc lb-echo -n default -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null)"
    [[ "$(echo "${lb_ips}" | wc -w)" -eq "${expected_lb_ips}" ]]
}
if ! poll 180 get_lb_ips; then
    oc describe svc lb-echo -n default || true
    fail "lb-echo did not receive ${expected_lb_ips} LoadBalancer IP(s) from the pool (got: '${lb_ips:-none}')"
else
    # ToR convergence takes ~15-20s after advertisement; the poll absorbs it.
    paths_for_lb() {
        local ip="$1" af=ipv4 plen=32
        if is_v6 "${ip}"; then af=ipv6 plen=128; fi
        ${CLI} exec bgp-tor vtysh -c "show bgp ${af} unicast ${ip}/${plen}" 2>/dev/null \
            | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p'
    }
    check_lb_paths() {
        local paths
        paths="$(paths_for_lb "$1")"
        [[ "${paths:-0}" -eq "${nodes}" ]]
    }
    for ip in ${lb_ips}; do
        if ! poll 300 check_lb_paths "${ip}"; then
            fail "LB IP ${ip}: $(paths_for_lb "${ip}" || echo 0) BGP paths at the ToR, expected ${nodes}"
        fi
    done
fi

echo "[4/4] datapath: the LB service answers over the BGP-routed path (every family)"
# success is the curl exit code (HTTP success), not any response-body literal
if [[ -n "${lb_ips}" ]]; then
    for ip in ${lb_ips}; do
        url="http://${ip}:8080/hostname"
        if is_v6 "${ip}"; then url="http://[${ip}]:8080/hostname"; fi
        check_datapath() {
            curl -g --fail --show-error --max-time 20 -s -o /dev/null "${url}"
        }
        if poll 300 check_datapath; then
            echo "LB service reachable over BGP via ${ip}"
        else
            ip route get "${ip}" 2>/dev/null || ip -6 route get "${ip}" 2>/dev/null || true
            fail "LB service ${url} not reachable from the hypervisor"
        fi
    done
else
    echo "skipping datapath check: no LB IP"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + MetalLB coexistence verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + MetalLB coexistence verification passed"
EOF
