#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip ovn-bgp evpn verify command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

rc=0
ssh "${SSHOPTS[@]}" "root@${IP}" \
    "EVPN_L3VNI='${EVPN_L3VNI}' EVPN_CUDN_SUBNET_V4='${EVPN_CUDN_SUBNET_V4}' EVPN_CUDN_SUBNET_V6='${EVPN_CUDN_SUBNET_V6}'" \
    bash -x - << 'EOF' || rc=$?
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

# Shared with baremetalds-e2e-ovn-bgp-pre and the ovn-kubernetes OTE
# baremetal infraprovider: route reflector container 'frr' at RR_IP, iBGP
# AS 64512; VIP ToR container 'bgp-tor'.
RR_CONTAINER=frr
RR_IP=192.168.111.3
BGP_AS=64512
TOR_CONTAINER=bgp-tor
NS=bgp-vip-evpn-check
CUDN=bgp-vip-evpn-check
VTEP=bgp-vip-evpn-check
ART=/tmp/evpn-artifacts
mkdir -p "${ART}"

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}
poll() {
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 10
    done
}

collect() {
    ${CLI} exec "${RR_CONTAINER}" vtysh -c 'show bgp l2vpn evpn summary' > "${ART}/rr-l2vpn-evpn-summary.txt" 2>&1 || true
    ${CLI} exec "${RR_CONTAINER}" vtysh -c 'show bgp l2vpn evpn' > "${ART}/rr-l2vpn-evpn.txt" 2>&1 || true
    oc get frrconfiguration -n openshift-frr-k8s -o yaml > "${ART}/frrconfigurations.yaml" 2>&1 || true
    oc get vtep,clusteruserdefinednetwork,routeadvertisements -A -o yaml > "${ART}/evpn-crs.yaml" 2>&1 || true
    oc get pods -n "${NS}" -o wide > "${ART}/pods.txt" 2>&1 || true
    oc describe pods -n "${NS}" > "${ART}/pods-describe.txt" 2>&1 || true
    for p in $(oc get pods -n openshift-frr-k8s -o name 2>/dev/null); do
        oc exec -n openshift-frr-k8s "${p}" -c frr -- vtysh -c 'show bgp l2vpn evpn summary' > "${ART}/${p##*/}-l2vpn-summary.txt" 2>&1 || true
    done
}
cleanup() {
    collect
    # leave the cluster exactly as the ovn-bgp pre step left it: the OTE
    # suite creates its own VTEPs/CUDNs and expects no leftovers
    oc delete routeadvertisements "${CUDN}" --ignore-not-found --timeout=120s || true
    oc delete pod -n "${NS}" --all --timeout=120s --ignore-not-found || true
    oc delete clusteruserdefinednetwork "${CUDN}" --ignore-not-found --timeout=180s || true
    oc delete namespace "${NS}" --ignore-not-found --timeout=180s || true
    oc delete vtep "${VTEP}" --ignore-not-found --timeout=120s || true
}
if [[ "${EVPN_KEEP:-false}" == "true" ]]; then trap collect EXIT; else trap cleanup EXIT; fi

masters="$(oc get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l)"
api_vips="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.apiServerInternalIPs[*]}')"
ingress_vips="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.ingressIPs[*]}')"
master_node="$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')"
master_ip="$(oc get node "${master_node}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -v : | head -1)"
node_ips_v4="$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -v ':' | sort -u)"
node_cidr_v4="$(ip -4 -o addr show dev ostestbm | awk '{print $4}' | head -1)"
node_net_v4="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "${node_cidr_v4}")"
dualstack=false
[[ "$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[*].cidr}')" == *:* ]] && dualstack=true

# ----------------------------------------------------------------------------
echo "[0/5] preconditions: route reflector up, local gateway mode (EVPN requirement)"
${CLI} inspect "${RR_CONTAINER}" --format '{{.State.Running}}' | grep -q true \
    || { echo "route reflector '${RR_CONTAINER}' not running; baremetalds-e2e-ovn-bgp-pre must precede this step"; exit 1; }
if [[ "$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}')" != "true" ]]; then
    echo "cluster is not in local gateway mode; EVPN requires routingViaHost=true (ovn-shared-to-local-gateway-mode-migration must precede this step)"
    exit 1
fi

# l2vpn-evpn address family on the route reflector, every node an RR client.
# Idempotent and identical in effect to what the OTE suite configures.
evpn_cmds="configure terminal
router bgp ${BGP_AS}
 address-family l2vpn evpn
  advertise-all-vni"
for ip in ${node_ips_v4}; do
    evpn_cmds+="
  neighbor ${ip} activate
  neighbor ${ip} route-reflector-client"
done
evpn_cmds+="
 exit-address-family
end"
${CLI} exec "${RR_CONTAINER}" vtysh -c "${evpn_cmds}"

# The shared ovn-bgp FRRConfiguration sets disableMP; EVPN is an MP
# address family on the IPv4 session. Record whether it was set so the
# finding is visible, then clear it (the OTE suite needs the same).
if oc get frrconfiguration -n openshift-frr-k8s receive-filtered -o json | jq -e '[.spec.bgp.routers[].neighbors[].disableMP // false] | any' >/dev/null; then
    echo "info: receive-filtered had disableMP=true; clearing it for the l2vpn-evpn address family"
    oc get frrconfiguration -n openshift-frr-k8s receive-filtered -o json \
        | jq 'del(.spec.bgp.routers[].neighbors[].disableMP)' | oc apply -f -
fi

# ----------------------------------------------------------------------------
echo "[1/5] throw-away Layer3 EVPN CUDN + VTEP + RouteAdvertisements accepted"
oc apply -f - <<YAML
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: ${VTEP}
spec:
  mode: Unmanaged
  cidrs:
  - ${node_net_v4}
YAML
check_vtep() { oc get vtep "${VTEP}" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; }
if ! poll 300 check_vtep; then
    oc get vtep "${VTEP}" -o yaml || true
    fail "VTEP ${VTEP} not Accepted"
fi

# a Primary-role CUDN only attaches to namespaces carrying the
# k8s.ovn.org/primary-user-defined-network label, and an admission policy
# forbids adding it after creation - so the labels go on the namespace object
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    bgp-vip-evpn-check: ""
    k8s.ovn.org/primary-user-defined-network: ""
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
YAML
subnets="        - cidr: ${EVPN_CUDN_SUBNET_V4}
          hostSubnet: 24"
${dualstack} && subnets+="
        - cidr: ${EVPN_CUDN_SUBNET_V6}
          hostSubnet: 64"
oc apply -f - <<YAML
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${CUDN}
  labels:
    bgp-vip-evpn-check: ""
spec:
  namespaceSelector:
    matchLabels:
      bgp-vip-evpn-check: ""
  network:
    topology: Layer3
    transport: EVPN
    layer3:
      role: Primary
      subnets:
${subnets}
    evpn:
      vtep: ${VTEP}
      ipVRF:
        vni: ${EVPN_L3VNI}
---
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: ${CUDN}
spec:
  nodeSelector: {}
  # select only the ovn-bgp route reflector FRRConfiguration: an empty
  # selector would also match the BGP VIP one and ovn-k would template the
  # EVPN session onto the VIP ToR peer
  frrConfigurationSelector:
    matchLabels:
      network: default
  networkSelectors:
  - networkSelectionType: ClusterUserDefinedNetworks
    clusterUserDefinedNetworkSelector:
      networkSelector:
        matchLabels:
          bgp-vip-evpn-check: ""
  # EVPN networks live in an ovn-k managed VRF; 'auto' selects it
  targetVRF: auto
  advertisements:
  - PodNetwork
YAML
check_cudn() {
    [[ "$(oc get clusteruserdefinednetwork "${CUDN}" -o jsonpath='{.status.conditions[?(@.type=="NetworkCreated")].status}')" == True ]] \
    && [[ "$(oc get routeadvertisements "${CUDN}" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" == True ]]
}
if ! poll 300 check_cudn; then
    oc get clusteruserdefinednetwork "${CUDN}" -o yaml || true
    oc get routeadvertisements "${CUDN}" -o yaml || true
    fail "CUDN ${CUDN} not NetworkCreated or RouteAdvertisements not Accepted"
fi

# ----------------------------------------------------------------------------
echo "[2/5] pod pinned to control plane node ${master_node} is Ready on the EVPN network"
oc apply -n "${NS}" -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: evpn-master
spec:
  nodeName: ${master_node}
  tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.53
    args: ["netexec", "--http-port=8080", "--udp-port=0"]
YAML
if ! oc wait -n "${NS}" --for=condition=Ready pod/evpn-master --timeout=300s; then
    oc describe pod -n "${NS}" evpn-master || true
    fail "EVPN pod on ${master_node} did not become Ready"
fi

# ----------------------------------------------------------------------------
echo "[3/5] the master's EVPN FRRConfiguration is merged by the frr-k8s STATIC POD and its l2vpn-evpn session is Established"
# On the control plane the frr-k8s instance is the MCO-rendered static pod
# 'frr-k8s-<node>'; the DaemonSet is excluded there. This is the point of
# the lane: the ovn-k generated per-node EVPN configuration must be
# reconciled by that static pod, next to the eBGP VIP session.
static_pod="frr-k8s-${master_node}"
# ovn-k emits the EVPN part (vrf <x> / vni N, l2vpn evpn address family) as
# spec.raw.rawConfig on the per-node generated FRRConfiguration
check_frrconf_vni() {
    oc get frrconfiguration -n openshift-frr-k8s -o json \
        | jq -e --arg n "${master_node}" --arg v " vni ${EVPN_L3VNI}" \
            '[.items[] | select(.spec.nodeSelector.matchLabels["kubernetes.io/hostname"]==$n) | .spec.raw.rawConfig // ""] | any(contains($v))' >/dev/null
}
if ! poll 300 check_frrconf_vni; then
    oc get frrconfiguration -n openshift-frr-k8s -o yaml | grep -nE "name:|hostname|vni" || true
    fail "no FRRConfiguration for ${master_node} carries VNI ${EVPN_L3VNI}"
fi
check_static_pod_evpn() {
    oc exec -n openshift-frr-k8s "${static_pod}" -c frr -- vtysh -c 'show bgp l2vpn evpn summary json' 2>/dev/null \
        | jq -e '[.peers // {} | to_entries[] | select(.value.state=="Established")] | length > 0' >/dev/null
}
if ! poll 300 check_static_pod_evpn; then
    oc exec -n openshift-frr-k8s "${static_pod}" -c frr -- vtysh -c 'show bgp l2vpn evpn summary' || true
    oc exec -n openshift-frr-k8s "${static_pod}" -c frr -- vtysh -c 'show running-config' || true
    fail "frr-k8s static pod ${static_pod} has no Established l2vpn-evpn session"
fi
# the VNI must be programmed on the master (SVD vxlan device with vnifilter)
check_master_vni() {
    oc exec -n openshift-frr-k8s "${static_pod}" -c frr -- vtysh -c 'show evpn vni json' 2>/dev/null \
        | jq -e --arg v "${EVPN_L3VNI}" 'has($v)' >/dev/null
}
if ! poll 300 check_master_vni; then
    oc exec -n openshift-frr-k8s "${static_pod}" -c frr -- vtysh -c 'show evpn vni' || true
    fail "VNI ${EVPN_L3VNI} is not programmed on ${master_node}"
fi

# ----------------------------------------------------------------------------
echo "[4/5] the master's VTEP IP is its node IP, not a VIP, and the RR learns the master's CUDN subnet via that IP"
# Under BGP VIP management kube-vip holds the API/ingress VIPs as plain /32s
# on br-ex of every node. ovn-k's unmanaged VTEP discovery filters only
# keepalived-labelled and IFA_F_SECONDARY addresses, so a VIP inside the
# VTEP CIDR is chosen as the VTEP IP - every master then sources VXLAN from
# the API VIP and every worker from the ingress VIP, and the cross-node
# EVPN datapath is dead (OCPBUGS-130338). This is the coexistence contract.
check_vtep_annotation() {
    local v4
    v4="$(oc get node "${master_node}" -o json | jq -r --arg n "${VTEP}" '.metadata.annotations["k8s.ovn.org/node-vteps"] // "{}" | fromjson | .[$n].ips // [] | map(select(contains(":")|not)) | .[0] // empty')"
    [[ -n "${v4}" ]] || return 1
    echo "master ${master_node} VTEP annotation (v4): ${v4}; node IP: ${master_ip}"
    [[ "${v4}" == "${master_ip}" ]]
}
if ! poll 300 check_vtep_annotation; then
    oc get node "${master_node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-vteps}{"\n"}' || true
    for vip in ${api_vips} ${ingress_vips}; do
        echo "  (VIP on this cluster: ${vip})"
    done
    fail "VTEP IP selected on ${master_node} is not its node IP ${master_ip} - a BGP-managed VIP was picked as the VXLAN source (OCPBUGS-130338)"
fi
check_rr_type5_from_master() {
    # the master's per-node CUDN host subnet must be a type-5 route whose next hop is the master's node IP
    ${CLI} exec "${RR_CONTAINER}" vtysh -c 'show bgp l2vpn evpn route type prefix json' 2>/dev/null \
        | jq -e --arg nh "${master_ip}" '[.. | objects | select(has("nexthops")) | .nexthops[]?.ip] | index($nh) != null' >/dev/null
}
if ! poll 300 check_rr_type5_from_master; then
    ${CLI} exec "${RR_CONTAINER}" vtysh -c 'show bgp l2vpn evpn route type prefix' || true
    fail "route reflector has no EVPN type-5 route with next hop ${master_ip} (master's VTEP)"
fi

# ----------------------------------------------------------------------------
echo "[5/5] BGP VIP regression guard: VIPs unaffected with EVPN live on the control plane"
check_tor_sessions() {
    local established
    established="$(${CLI} exec "${TOR_CONTAINER}" vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null \
        | jq '[.ipv4Unicast.peers // .peers // {} | to_entries[] | select(.value.state=="Established")] | length')"
    [[ "${established:-0}" -ge "${masters}" ]]
}
if ! poll 120 check_tor_sessions; then
    ${CLI} exec "${TOR_CONTAINER}" vtysh -c 'show bgp summary' || true
    fail "fewer than ${masters} Established IPv4 sessions at the ToR with EVPN live"
fi
for vip in ${api_vips} ${ingress_vips}; do
    [[ "${vip}" == *:* ]] && continue
    if ! ${CLI} exec "${TOR_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${vip}/32 json" 2>/dev/null | jq -e '.paths | length > 0' >/dev/null; then
        fail "VIP ${vip}/32 no longer present at the ToR with EVPN live"
    fi
done
for vip in ${api_vips}; do
    [[ "${vip}" == *:* ]] && continue
    if ! curl -k --max-time 15 -s -o /dev/null "https://${vip}:6443/readyz"; then
        fail "API VIP ${vip} does not answer /readyz with EVPN live"
    fi
done

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + EVPN control-plane coexistence check failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + EVPN control-plane coexistence check passed"
EOF

scp "${SSHOPTS[@]}" -r "root@${IP}:/tmp/evpn-artifacts" "${ARTIFACT_DIR}/" 2>/dev/null || true
exit "${rc}"
