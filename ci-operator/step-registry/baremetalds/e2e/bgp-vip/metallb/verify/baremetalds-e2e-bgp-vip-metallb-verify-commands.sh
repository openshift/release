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

echo "[2/4] same-neighbor merge: still exactly one Established ToR session per node"
# vtysh prints a harmless 'vtysh.conf' warning on stderr; drop stderr and
# parse stdout only so pipefail is not tripped by the noise.
check_sessions() {
    local established
    established="$(${CLI} exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null \
        | jq '[.peers[] | select(.state=="Established")] | length')"
    [[ "${established:-0}" -eq "${nodes}" ]]
}
if ! poll 300 check_sessions; then
    ${CLI} exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary' || true
    fail "ToR does not have exactly ${nodes} Established sessions (MetalLB must merge into the existing neighbor, not add or flap sessions)"
fi

echo "[3/4] the LoadBalancer service IP is advertised to the ToR from every frr-k8s node"
lb_ip=""
get_lb_ip() {
    lb_ip="$(oc get svc lb-echo -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    [[ -n "${lb_ip}" ]]
}
if ! poll 180 get_lb_ip; then
    oc describe svc lb-echo -n default || true
    fail "lb-echo never received a LoadBalancer IP from the pool"
else
    # ToR /32 convergence takes ~15-20s after advertisement; the poll absorbs it.
    check_lb_paths() {
        local paths
        paths="$(${CLI} exec bgp-tor vtysh -c "show ip bgp ${lb_ip}/32" 2>/dev/null \
            | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p')"
        [[ "${paths:-0}" -eq "${nodes}" ]]
    }
    if ! poll 300 check_lb_paths; then
        ${CLI} exec bgp-tor vtysh -c "show ip bgp ${lb_ip}/32" || true
        fail "LB IP ${lb_ip}/32 does not have ${nodes} BGP paths at the ToR"
    fi
fi

echo "[4/4] datapath: the LB service answers over the BGP-routed path"
# success is the curl exit code (HTTP success), not any response-body literal
if [[ -n "${lb_ip}" ]]; then
    if curl --fail --show-error --max-time 20 -s "http://${lb_ip}:8080/hostname"; then
        echo "LB service reachable over BGP"
    else
        ip route get "${lb_ip}" || true
        fail "LB service ${lb_ip}:8080 not reachable from the hypervisor"
    fi
else
    echo "skipping datapath check: no LB IP"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + MetalLB coexistence verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + MetalLB coexistence verification passed"
EOF
