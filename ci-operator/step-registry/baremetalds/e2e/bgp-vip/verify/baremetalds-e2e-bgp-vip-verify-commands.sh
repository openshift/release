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

echo "[1/6] Infrastructure CR requests BGP VIP management"
vip_management="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.vipManagement}')"
if [[ "${vip_management}" != "BGP" ]]; then
    fail "vipManagement is '${vip_management}', expected 'BGP'"
fi

echo "[2/6] a Ready frr-k8s static pod runs on every control plane node"
masters="$(oc get nodes -l node-role.kubernetes.io/master -o name | wc -l)"
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
    ready="$(oc get pod -n openshift-frr-k8s "frr-k8s-${node}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" != "True" ]]; then
        fail "frr-k8s static pod on ${node} is not Ready (status: '${ready:-missing}')"
    fi
done

echo "[3/6] no keepalived pods (BGP replaces VRRP)"
keepalived="$(oc get pods --all-namespaces -o name | { grep -c keepalived || true; })"
if [[ "${keepalived}" -ne 0 ]]; then
    oc get pods --all-namespaces | grep keepalived || true
    fail "found ${keepalived} keepalived pods, expected none"
fi

echo "[4/6] every ToR BGP session is Established with the negotiated timers and BFD up"
# The expectations come from the bgp-vip FRRConfiguration the CNO rendered
# from the install-config: every ToR neighbor it declares must have an
# Established session from every master, with the negotiated hold/keepalive
# matching the neighbor's holdTime/keepaliveTime (FRR defaults 180s/60s when
# unset) and BFD Up when the neighbor references a bfdProfile. Comparing the
# negotiated values proves the node-side FRR actually applied the rendered
# config: a silently rejected "timers" line would leave the defaults in place
# and still establish. Reading them from the CR rather than hardcoding the
# dev-scripts defaults keeps this lane correct for whatever peer the
# install-config declares (timers/BFD/IPv6 are all optional there).
masters_total="$(oc get nodes -l node-role.kubernetes.io/master -o name | wc -l)"
bgp_vip_cr="$(oc get frrconfiguration -n openshift-frr-k8s bgp-vip -o json)"
tor_neighbors="$(printf '%s' "${bgp_vip_cr}" | jq -r '.spec.bgp.routers[0].neighbors[].address')"
if [[ -z "${tor_neighbors}" ]]; then
    printf '%s\n' "${bgp_vip_cr}" || true
    fail "bgp-vip FRRConfiguration declares no ToR neighbor"
fi
echo "ToR neighbors declared by bgp-vip: $(echo "${tor_neighbors}" | tr '\n' ' ')"
neighbors_json() {
    ${CLI} exec bgp-tor vtysh -c 'show bgp neighbors json' 2>/dev/null
}
check_sessions() {
    # ToR-side view (stdin) checked against the CR-side expectations (argv)
    neighbors_json | python3 -c '
import json, re, sys
tor = json.load(sys.stdin)
cr = json.loads(sys.argv[1])
masters = int(sys.argv[2])

def seconds(d, default):
    # metav1.Duration string such as "90s" or "1m30s"; FRR default when unset
    if not d:
        return default
    total, n = 0, ""
    for ch in d:
        if ch.isdigit():
            n += ch
        else:
            total += int(n) * {"h": 3600, "m": 60, "s": 1}[ch]
            n = ""
    return total

failures = []
for nb in cr["spec"]["bgp"]["routers"][0]["neighbors"]:
    addr = nb["address"]
    hold = seconds(nb.get("holdTime"), 180) * 1000
    keep = seconds(nb.get("keepaliveTime"), 60) * 1000
    want_bfd = bool(nb.get("bfdProfile"))
    # the ToR has one session per master to this neighbor address; vtysh keys
    # them by the node-side source address, so match on the remote view of
    # the neighbor instead (hostname carries the node, localAs/remoteAs the
    # peering) - every Established session to this family must match
    family6 = ":" in addr
    sessions = {a: n for a, n in tor.items() if (":" in a) == family6}
    established = [a for a, n in sessions.items() if n.get("bgpState") == "Established"]
    for a in sessions:
        n = sessions[a]
        state = n.get("bgpState")
        if state != "Established":
            failures.append(f"{a}: state {state}, expected Established")
            continue
        h, k = n.get("bgpTimerHoldTimeMsecs"), n.get("bgpTimerKeepAliveIntervalMsecs")
        if h != hold or k != keep:
            failures.append(f"{a}: negotiated timers hold={h}ms keepalive={k}ms, expected {hold}/{keep} from bgp-vip neighbor {addr} - the node-side FRR did not apply the rendered timers")
        bfd = n.get("peerBfdInfo", {}).get("status")
        profile = nb.get("bfdProfile")
        if want_bfd and bfd != "Up":
            failures.append(f"{a}: BFD status {bfd!r}, expected Up (bgp-vip neighbor {addr} references bfdProfile {profile!r})")
        if not want_bfd and bfd == "Up":
            failures.append(f"{a}: BFD is Up but bgp-vip neighbor {addr} declares no bfdProfile")
    if len(established) < masters:
        failures.append(f"neighbor {addr}: {len(established)} Established session(s) at the ToR, expected at least {masters} (one per master)")
for f in failures:
    print(f)
sys.exit(1 if failures else 0)
' "${bgp_vip_cr}" "${masters_total}"
}
if ! poll 300 check_sessions; then
    neighbors_json || true
    fail "BGP sessions at the ToR do not match the bgp-vip FRRConfiguration (Established, negotiated timers, BFD)"
fi

echo "[5/6] ToR sees every VIP of every address family with the expected path counts"
# A VIP can only reach the ToR over a BGP session of its own address family,
# so assert paths only for the families the bgp-vip FRRConfiguration peers on
# (a dual-stack cluster whose install-config declares a v4 ToR peer only
# advertises its v4 VIPs; the v6 VIPs are still served, just not via BGP).
advertised_families() {
    local vip
    for vip in "$@"; do
        if is_v6 "${vip}"; then
            echo "${tor_neighbors}" | grep -q ':' && echo "${vip}" || echo "skipping ${vip}: bgp-vip declares no IPv6 ToR neighbor" >&2
        else
            echo "${tor_neighbors}" | grep -qv ':' && echo "${vip}" || echo "skipping ${vip}: bgp-vip declares no IPv4 ToR neighbor" >&2
        fi
    done
}
# shellcheck disable=SC2046
api_vips="$(advertised_families $(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIPs[*]}'))"
# shellcheck disable=SC2046
ingress_vips="$(advertised_families $(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.ingressIPs[*]}'))"
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

echo "[6/6] console answers over the BGP-routed ingress VIP of every family"
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
