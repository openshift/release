#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Configuring guest cluster for EgressIP on a secondary host interface ************"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

GUEST_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
MGMT_KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
if [[ ! -f "${MGMT_KUBECONFIG}" ]]; then
  MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

guest() { oc --kubeconfig="${GUEST_KUBECONFIG}" "$@"; }
mgmt()  { oc --kubeconfig="${MGMT_KUBECONFIG}" "$@"; }

CLUSTER_NAME="$(cat "${SHARED_DIR}/cluster-name")"
# Match on the first three octets of the extra network so we can find the NIC by address.
BASE_SUBNET_PREFIX="${EGRESSIP_SECONDARY_SUBNET%.*/*}."

EGRESSIP_VLAN_ID="${EGRESSIP_VLAN_ID:-}"
EGRESSIP_VLAN_SUBNET="${EGRESSIP_VLAN_SUBNET:-}"
EGRESSIP_VLAN_IFNAME="${EGRESSIP_VLAN_IFNAME:-vlan-egress}"

if [[ -n "${EGRESSIP_VLAN_ID}" && -z "${EGRESSIP_VLAN_SUBNET}" ]]; then
  echo "ERROR: EGRESSIP_VLAN_ID requires EGRESSIP_VLAN_SUBNET"
  exit 1
fi

# sysctl(8) parses '.' as its separator, so an interface named enp3s0.3686 makes
# net.ipv4.conf.enp3s0.3686.forwarding ambiguous and the Tuned [sysctl] keys below
# would silently not apply. Reject the dot rather than discover it as a no-op.
if [[ "${EGRESSIP_VLAN_IFNAME}" == *.* ]]; then
  echo "ERROR: EGRESSIP_VLAN_IFNAME must not contain '.' (got '${EGRESSIP_VLAN_IFNAME}')"
  exit 1
fi

echo "Guest cluster: ${CLUSTER_NAME}, secondary subnet: ${EGRESSIP_SECONDARY_SUBNET}"
if [[ -n "${EGRESSIP_VLAN_ID}" ]]; then
  echo "Egress traffic will be tagged: VLAN ${EGRESSIP_VLAN_ID} on ${EGRESSIP_VLAN_SUBNET}"
fi

# IPv4 helpers. The step image has no ipcalc and python3 is not guaranteed, so the
# little arithmetic needed to place a host inside the VLAN subnet is done here.
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}
int2ip() {
  local i="$1"
  echo "$(( (i >> 24) & 255 )).$(( (i >> 16) & 255 )).$(( (i >> 8) & 255 )).$(( i & 255 ))"
}

#
# 1. Find the secondary interface. dev-scripts attaches NICs in the order
#    provisioning, baremetal, extra... so the extra NIC is whichever link carries an
#    address out of the extra network's DHCP range. Discover it rather than assume
#    a name, since the enumeration depends on how many networks were requested.
#
NODES="$(guest get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${NODES}" ]]; then
  echo "ERROR: no nodes found in the guest cluster"
  exit 1
fi
echo "Guest nodes: $(echo "${NODES}" | tr '\n' ' ')"

BASE_IFACE=""
BASE_ADDRS="$(mktemp)"
for node in ${NODES}; do
  echo "Looking for an address in ${BASE_SUBNET_PREFIX}0/24 on ${node}..."
  found=""
  for _ in $(seq 1 30); do
    found="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -o -4 addr show 2>/dev/null \
      | awk -v pfx="${BASE_SUBNET_PREFIX}" '$4 ~ "^"pfx {split($4, a, "/"); print $2, a[1]; exit}')" || true
    [[ -n "${found}" ]] && break
    sleep 10
  done
  if [[ -z "${found}" ]]; then
    echo "ERROR: ${node} has no address in ${EGRESSIP_SECONDARY_SUBNET}."
    echo "       The extra libvirt network was probably not requested. Confirm the job sets"
    echo "       EXTRA_NETWORK_CONFIG and that baremetalds-devscripts-conf-extranetwork ran"
    echo "       before dev-scripts provisioned the hosts."
    guest debug -n default "node/${node}" --quiet -- chroot /host ip -o addr show || true
    exit 1
  fi
  iface="${found%% *}"
  addr="${found##* }"
  echo "  ${node}: ${iface} ${addr}"
  echo "${node} ${addr}" >> "${BASE_ADDRS}"
  if [[ -z "${BASE_IFACE}" ]]; then
    BASE_IFACE="${iface}"
  elif [[ "${BASE_IFACE}" != "${iface}" ]]; then
    echo "ERROR: interface name differs across nodes (${BASE_IFACE} vs ${iface} on ${node})."
    echo "       A single Tuned profile cannot cover both; aborting rather than half-configuring."
    exit 1
  fi
done
echo "Secondary interface: ${BASE_IFACE}"

#
# 1b. Optionally put an 802.1Q interface on top of it. The customer topology this
#     models does not address the physical link at all; the egress subnet lives on a
#     tagged interface configured per host, with the untagged link only carrying the
#     tag. Here the untagged address stays where libvirt's DHCP put it, because it is
#     what lets us find the link in the first place, and it is harmless: the EgressIP
#     is drawn from the VLAN subnet, so OVN-Kubernetes binds it to the VLAN interface.
#
#     Addresses are static, since nothing serves DHCP on the tagged segment. Each node
#     keeps the host part it already has on the untagged network, which keeps the
#     numbering aligned with libvirt's reservations and avoids depending on the order
#     nodes come back from the API.
#
if [[ -n "${EGRESSIP_VLAN_ID}" ]]; then
  vlan_net_int="$(ip2int "${EGRESSIP_VLAN_SUBNET%/*}")"
  vlan_prefix_len="${EGRESSIP_VLAN_SUBNET#*/}"
  vlan_size=$(( 1 << (32 - vlan_prefix_len) ))
  vlan_bcast_int=$(( vlan_net_int + vlan_size - 1 ))

  # Read on fd 3: oc debug attaches stdin, so a plain "done < file" loop would have the
  # first debug pod consume the remaining nodes and silently configure only one of them.
  while read -r node addr <&3; do
    host_part="${addr##*.}"
    vlan_addr_int=$(( vlan_net_int + host_part ))
    if (( vlan_addr_int <= vlan_net_int || vlan_addr_int >= vlan_bcast_int )); then
      echo "ERROR: ${node} has host part ${host_part}, which does not fit inside"
      echo "       ${EGRESSIP_VLAN_SUBNET}. Widen the VLAN subnet or align it with the"
      echo "       untagged network's DHCP range."
      exit 1
    fi
    vlan_addr="$(int2ip ${vlan_addr_int})"

    echo "Creating ${EGRESSIP_VLAN_IFNAME} (VLAN ${EGRESSIP_VLAN_ID}) on ${node} with ${vlan_addr}/${vlan_prefix_len}..."
    guest debug -n default "node/${node}" --quiet -- chroot /host bash -c "
      set -e
      if nmcli -g NAME connection show | grep -qx '${EGRESSIP_VLAN_IFNAME}'; then
        nmcli connection delete '${EGRESSIP_VLAN_IFNAME}'
      fi
      nmcli connection add type vlan con-name '${EGRESSIP_VLAN_IFNAME}' \
        ifname '${EGRESSIP_VLAN_IFNAME}' dev '${BASE_IFACE}' id '${EGRESSIP_VLAN_ID}' \
        ipv4.method manual ipv4.addresses '${vlan_addr}/${vlan_prefix_len}' \
        ipv4.never-default yes ipv6.method disabled
      nmcli connection up '${EGRESSIP_VLAN_IFNAME}'
      ip -o -4 addr show dev '${EGRESSIP_VLAN_IFNAME}'
    " </dev/null
  done 3< "${BASE_ADDRS}"

  EGRESS_IFACE="${EGRESSIP_VLAN_IFNAME}"
  EGRESS_SUBNET="${EGRESSIP_VLAN_SUBNET}"
else
  EGRESS_IFACE="${BASE_IFACE}"
  EGRESS_SUBNET="${EGRESSIP_SECONDARY_SUBNET}"
fi

# From here on EGRESS_IFACE is the link that carries the EgressIP, tagged or not.
EGRESS_SUBNET_PREFIX="${EGRESS_SUBNET%.*/*}."
echo "EgressIP interface: ${EGRESS_IFACE}, subnet: ${EGRESS_SUBNET}"

#
# 2. Global IP forwarding. The default of Restricted sets the kernel FORWARD policy to
#    DROP and only allows traffic OVN-Kubernetes itself needs. Pod traffic entering on
#    ovn-k8s-mp0 and leaving on the secondary NIC is not in that allowlist.
#    Note this is deliberately NOT paired with routingViaHost: a secondary-interface
#    EgressIP already reroutes the selected pods to the management port regardless of
#    gateway mode, so local gateway mode is not a prerequisite.
#
current_fwd="$(guest get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}' || true)"
if [[ "${current_fwd}" == "Global" ]]; then
  echo "Guest CNO already has ipForwarding=Global"
else
  echo "Patching guest CNO with ipForwarding=Global (was '${current_fwd:-unset}')..."
  guest patch network.operator.openshift.io cluster --type=merge -p \
    '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'

  echo "Waiting for the network cluster operator to settle..."
  for _ in $(seq 1 60); do
    progressing="$(guest get co network -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' || true)"
    available="$(guest get co network -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)"
    if [[ "${progressing}" == "False" && "${available}" == "True" ]]; then
      echo "Network operator settled"
      break
    fi
    sleep 10
  done
  guest get co network
fi

#
# 3. Per-interface forwarding sysctl, delivered by the Node Tuning Operator.
#    ipForwarding: Global only changes the netfilter FORWARD policy; OVN-Kubernetes sets
#    net.ipv4.conf.<iface>.forwarding only on br-ex and ovn-k8s-mp0, never on a NIC it
#    does not manage. rp_filter is relaxed to loose mode so replies arriving on the
#    secondary NIC survive the reverse-path check, whose main-table lookup points at br-ex.
#    On HyperShift a Tuned object reaches guest nodes through NodePool.spec.tuningConfig.
#
NODEPOOLS="$(mgmt get nodepool -n "${HYPERSHIFT_NAMESPACE}" \
  -o jsonpath="{range .items[?(@.spec.clusterName=='${CLUSTER_NAME}')]}{.metadata.name}{'\n'}{end}")"
if [[ -z "${NODEPOOLS}" ]]; then
  echo "ERROR: no NodePool found for HostedCluster ${CLUSTER_NAME} in ${HYPERSHIFT_NAMESPACE}"
  exit 1
fi
echo "NodePools: $(echo "${NODEPOOLS}" | tr '\n' ' ')"

cat <<EOF | mgmt apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${TUNED_CONFIGMAP_NAME}
  namespace: ${HYPERSHIFT_NAMESPACE}
data:
  tuning: |
    apiVersion: tuned.openshift.io/v1
    kind: Tuned
    metadata:
      name: egressip-multinic
      namespace: openshift-cluster-node-tuning-operator
    spec:
      profile:
      - name: egressip-multinic
        data: |
          [main]
          summary=Enable forwarding on the EgressIP secondary interface
          include=openshift-node
          [sysctl]
          net.ipv4.conf.${EGRESS_IFACE}.forwarding=1
          net.ipv4.conf.${EGRESS_IFACE}.rp_filter=2
      recommend:
      - priority: 20
        profile: egressip-multinic
EOF

for np in ${NODEPOOLS}; do
  echo "Attaching ${TUNED_CONFIGMAP_NAME} to NodePool ${np}..."
  mgmt patch nodepool -n "${HYPERSHIFT_NAMESPACE}" "${np}" --type=merge -p \
    "{\"spec\":{\"tuningConfig\":[{\"name\":\"${TUNED_CONFIGMAP_NAME}\"}]}}"
done

echo "Waiting for the sysctl to land on every guest node..."
for node in ${NODES}; do
  ok=""
  for _ in $(seq 1 30); do
    value="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host sysctl -n "net.ipv4.conf.${EGRESS_IFACE}.forwarding" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "${value}" == "1" ]]; then
      ok="yes"
      break
    fi
    sleep 10
  done
  if [[ -z "${ok}" ]]; then
    echo "ERROR: net.ipv4.conf.${EGRESS_IFACE}.forwarding is not 1 on ${node}"
    guest get pods -n openshift-cluster-node-tuning-operator || true
    exit 1
  fi
  echo "  ${node}: forwarding=1"
done

#
# 4. Stop the secondary NIC from installing a competing default route.
#    The extra libvirt network is forward_mode=nat, so its dnsmasq hands out DHCP
#    option 3 pointing at the bridge address. Without this the node ends up with two
#    default routes and the winner depends on NetworkManager's metric assignment.
#    This is a runtime fix appropriate for CI. The supported production equivalent is
#    day-1 NIC configuration (NMStateConfig on the InfraEnv, or a MachineConfig
#    NetworkManager keyfile in NodePool.spec.config); Red Hat does not support
#    configuring a NIC post-installation on an OVN-Kubernetes cluster.
#
#    This applies to the untagged link even when the EgressIP lives on a VLAN above it,
#    because the DHCP lease is what carries the offending gateway. The VLAN interface
#    is created statically with no gateway at all, so it has nothing to withdraw.
if [[ "${EGRESSIP_SECONDARY_NEVER_DEFAULT}" == "true" ]]; then
  for node in ${NODES}; do
    echo "Setting ipv4.never-default on ${BASE_IFACE} (${node})..."
    guest debug -n default "node/${node}" --quiet -- chroot /host bash -c "
      set -e
      conn=\$(nmcli -g GENERAL.CONNECTION device show ${BASE_IFACE})
      if [[ -z \"\${conn}\" || \"\${conn}\" == '--' ]]; then
        echo 'no active NetworkManager connection on ${BASE_IFACE}'
        exit 1
      fi
      nmcli connection modify \"\${conn}\" ipv4.never-default yes
      nmcli device reapply ${BASE_IFACE} || nmcli connection up \"\${conn}\"
    "
  done

  echo "Verifying a single default route per node..."
  for node in ${NODES}; do
    routes="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -4 route show default 2>/dev/null)" || true
    echo "  ${node}: $(echo "${routes}" | tr '\n' '|')"
    for iface in "${BASE_IFACE}" "${EGRESS_IFACE}"; do
      if echo "${routes}" | grep -q "dev ${iface}"; then
        echo "ERROR: ${node} still has a default route via ${iface}"
        exit 1
      fi
    done
  done
fi

#
# 5. Confirm OVN-Kubernetes now considers the secondary subnet eligible. The
#    cluster-manager in the hosted control plane picks egress nodes purely from this
#    annotation, so if the subnet is missing here no EgressIP will ever be assigned.
#
echo "Checking k8s.ovn.org/host-cidrs..."
for node in ${NODES}; do
  ok=""
  for _ in $(seq 1 18); do
    cidrs="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' || true)"
    if [[ "${cidrs}" == *"${EGRESS_SUBNET_PREFIX}"* ]]; then
      ok="yes"
      break
    fi
    sleep 10
  done
  if [[ -z "${ok}" ]]; then
    echo "ERROR: ${node} host-cidrs does not advertise ${EGRESS_SUBNET}: ${cidrs:-<empty>}"
    if [[ -n "${EGRESSIP_VLAN_ID}" ]]; then
      echo "       The VLAN interface exists but ovnkube-node is not advertising its"
      echo "       subnet, so no EgressIP from it can ever be assigned."
    fi
    exit 1
  fi
  echo "  ${node}: ${cidrs}"
done

#
# 6. Publish what we found. Addresses come from libvirt DHCP reservations allocated in
#    flavor-iteration order, not hostname order, so downstream tests must read them from
#    here (or from the node annotation) instead of hardcoding. The same two files
#    describe both topologies, so a test does not need to know whether it is running
#    against a tagged or untagged egress path.
#
echo "${EGRESS_IFACE}" > "${SHARED_DIR}/egressip_secondary_iface"
echo "${EGRESS_SUBNET}" > "${SHARED_DIR}/egressip_secondary_subnet"
if [[ -n "${EGRESSIP_VLAN_ID}" ]]; then
  echo "${EGRESSIP_VLAN_ID}" > "${SHARED_DIR}/egressip_secondary_vlan_id"
fi
: > "${SHARED_DIR}/egressip_secondary_node_ips"
for node in ${NODES}; do
  addr="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' \
    | tr -d '[]"' | tr ',' '\n' | grep "^${EGRESS_SUBNET_PREFIX}" | head -1)" || true
  echo "${node} ${addr}" >> "${SHARED_DIR}/egressip_secondary_node_ips"
done

echo "************ Guest cluster ready for EgressIP on ${EGRESS_IFACE} ************"
cat "${SHARED_DIR}/egressip_secondary_node_ips"
