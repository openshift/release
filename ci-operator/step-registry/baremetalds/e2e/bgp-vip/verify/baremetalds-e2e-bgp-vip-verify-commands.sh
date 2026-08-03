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

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

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
keepalived="$(oc get pods --all-namespaces -o name | grep -c keepalived || true)"
if [[ "${keepalived}" -ne 0 ]]; then
    oc get pods --all-namespaces | grep keepalived || true
    fail "found ${keepalived} keepalived pods, expected none"
fi

echo "[4/5] ToR sees the VIP routes over BGP with the expected path counts"
api_vip="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIPs[0]}')"
ingress_vip="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.ingressIPs[0]}')"
workers="$(oc get nodes -l node-role.kubernetes.io/worker -o name | grep -cv master || true)"
# the ingress VIP is advertised from every node hosting a Ready router pod
router_nodes="$(oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
    --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | grep -c . || true)"
podman exec bgp-tor vtysh -c 'show ip bgp'
paths_for() {
    podman exec bgp-tor vtysh -c "show ip bgp $1/32" | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p'
}
api_paths="$(paths_for "${api_vip}")"
if [[ "${api_paths:-0}" -ne "${masters}" ]]; then
    fail "API VIP ${api_vip}/32: ${api_paths:-0} BGP path(s) at the ToR, expected exactly ${masters} (one per master)"
fi
if [[ "${workers}" -eq 0 ]]; then
    fail "no worker nodes found, but this lane deploys workers (ingress VIP advertisement untestable)"
else
    ingress_paths="$(paths_for "${ingress_vip}")"
    if [[ "${ingress_paths:-0}" -ne "${router_nodes}" ]]; then
        fail "ingress VIP ${ingress_vip}/32: ${ingress_paths:-0} BGP path(s) at the ToR, expected exactly ${router_nodes} (one per node with a Ready router pod)"
    fi
fi

echo "[5/5] console answers over the BGP-routed ingress VIP"
console_url="$(oc whoami --show-console)"
console_host="${console_url#https://}"
console_host="${console_host%%/*}"
# pin resolution to the ingress VIP and bypass proxies so the request
# provably traverses the BGP-advertised route
http_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 --noproxy '*' \
    --resolve "${console_host}:443:${ingress_vip}" "https://${console_host}")"
if [[ "${http_code}" != "200" ]]; then
    fail "console at ${console_host} via ${ingress_vip} returned HTTP ${http_code}, expected 200"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP verification passed"
EOF
