#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip verify command ************"

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

# poll <deadline-seconds> <function> — re-evaluate until success or timeout
poll() {
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 10
    done
}

is_v6() { [[ "$1" == *:* ]]; }

echo "[1/5] Infrastructure CR requests BGP VIP management"
vip_management="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.vipManagement}')"
if [[ "${vip_management}" != "BGP" ]]; then
    fail "vipManagement is '${vip_management}', expected 'BGP'"
fi

echo "[2/5] a Ready frr-k8s static pod runs on every control plane node"
masters="$(oc get nodes -l node-role.kubernetes.io/master -o name | wc -l)"
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
    ready="$(oc get pod -n openshift-frr-k8s "frr-k8s-${node}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" != "True" ]]; then
        fail "frr-k8s static pod on ${node} is not Ready (status: '${ready:-missing}')"
    fi
done

echo "[3/5] no keepalived pods (BGP replaces VRRP)"
keepalived="$(oc get pods --all-namespaces -o name | { grep -c keepalived || true; })"
if [[ "${keepalived}" -ne 0 ]]; then
    oc get pods --all-namespaces | grep keepalived || true
    fail "found ${keepalived} keepalived pods, expected none"
fi

echo "[4/5] ToR sees every VIP of every address family with the expected path counts"
api_vips="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIPs[*]}')"
ingress_vips="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.ingressIPs[*]}')"
workers="$(oc get nodes -l node-role.kubernetes.io/worker -o name | { grep -cv master || true; })"
# the ingress VIPs are advertised from every node hosting a Ready router pod
router_nodes="$(oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
    --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | { grep -c . || true; })"
${CLI} exec bgp-tor vtysh -c 'show ip bgp' 2>/dev/null || true
${CLI} exec bgp-tor vtysh -c 'show bgp ipv6 unicast' 2>/dev/null || true
paths_for() {
    # <vip>: per-family address family and prefix length
    local vip="$1" af=ipv4 plen=32
    if is_v6 "${vip}"; then af=ipv6; plen=128; fi
    ${CLI} exec bgp-tor vtysh -c "show bgp ${af} unicast ${vip}/${plen}" 2>/dev/null \
        | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p'
}
check_vip_paths() {
    # <vip> <expected> — polled: BGP convergence per family may lag
    local paths
    paths="$(paths_for "$1")"
    [[ "${paths:-0}" -eq "$2" ]]
}
for vip in ${api_vips}; do
    if ! poll 300 check_vip_paths "${vip}" "${masters}"; then
        fail "API VIP ${vip}: $(paths_for "${vip}" || echo 0) BGP path(s) at the ToR, expected exactly ${masters} (one per master)"
    fi
done
if [[ "${workers}" -eq 0 ]]; then
    fail "no worker nodes found, but this lane deploys workers (ingress VIP advertisement untestable)"
else
    for vip in ${ingress_vips}; do
        if ! poll 300 check_vip_paths "${vip}" "${router_nodes}"; then
            fail "ingress VIP ${vip}: $(paths_for "${vip}" || echo 0) BGP path(s) at the ToR, expected exactly ${router_nodes} (one per node with a Ready router pod)"
        fi
    done
fi

echo "[5/5] console answers over the BGP-routed ingress VIP of every family"
console_url="$(oc whoami --show-console)"
console_host="${console_url#https://}"
console_host="${console_host%%/*}"
for vip in ${ingress_vips}; do
    resolve_addr="${vip}"
    if is_v6 "${vip}"; then resolve_addr="[${vip}]"; fi
    # pin resolution to the ingress VIP and bypass proxies so the request
    # provably traverses the BGP-advertised route
    http_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 --noproxy '*' \
        --resolve "${console_host}:443:${resolve_addr}" "https://${console_host}")"
    if [[ "${http_code}" != "200" ]]; then
        fail "console at ${console_host} via ${vip} returned HTTP ${http_code}, expected 200"
    fi
done

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP verification passed"
EOF
