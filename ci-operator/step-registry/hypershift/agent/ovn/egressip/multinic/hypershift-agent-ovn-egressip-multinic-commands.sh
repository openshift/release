#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Configuring guest cluster for EgressIP on secondary host interfaces ************"

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

EGRESSIP_SECONDARY_SUBNET_2="${EGRESSIP_SECONDARY_SUBNET_2:-}"
EGRESSIP_REMOTE_SUBNET="${EGRESSIP_REMOTE_SUBNET:-}"
EGRESSIP_VLAN_ID="${EGRESSIP_VLAN_ID:-}"

#
# One slot per extra libvirt network. Slot 1 is the interface the VLAN step layers a
# tagged subinterface on when EGRESSIP_VLAN_ID is set; slot 2, when the job asks for it,
# is a second independent NIC on its own L2 segment that stays untagged. Keeping them
# distinct is the point of having two: it is what lets a job exercise two secondary
# host networks whose EgressIPs must not interfere.
#
SUBNETS=("${EGRESSIP_SECONDARY_SUBNET}")
if [[ -n "${EGRESSIP_SECONDARY_SUBNET_2}" ]]; then
  SUBNETS+=("${EGRESSIP_SECONDARY_SUBNET_2}")
fi

# Match on the first three octets of each extra network so we can find its NIC by address.
PREFIXES=()
for subnet in "${SUBNETS[@]}"; do
  PREFIXES+=("${subnet%.*/*}.")
done

echo "Guest cluster: ${CLUSTER_NAME}"
for i in "${!SUBNETS[@]}"; do
  echo "  secondary network $((i + 1)): ${SUBNETS[$i]}"
done

#
# 1. Find each secondary interface. dev-scripts attaches NICs in the order
#    provisioning, baremetal, extra... so an extra NIC is whichever link carries an
#    address out of that network's DHCP range. Discover them rather than assume names,
#    since the enumeration depends on how many networks were requested.
#
NODES="$(guest get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${NODES}" ]]; then
  echo "ERROR: no nodes found in the guest cluster"
  exit 1
fi
echo "Guest nodes: $(echo "${NODES}" | tr '\n' ' ')"

IFACES=()
for i in "${!SUBNETS[@]}"; do
  prefix="${PREFIXES[$i]}"
  found_iface=""
  for node in ${NODES}; do
    echo "Looking for an address in ${prefix}0/24 on ${node}..."
    iface=""
    for _ in $(seq 1 30); do
      iface="$(guest debug -n default "node/${node}" --quiet -- \
        chroot /host ip -o -4 addr show 2>/dev/null \
        | awk -v pfx="${prefix}" '$4 ~ "^"pfx {print $2; exit}')" || true
      [[ -n "${iface}" ]] && break
      sleep 10
    done
    if [[ -z "${iface}" ]]; then
      echo "ERROR: ${node} has no address in ${SUBNETS[$i]}."
      echo "       The extra libvirt network was probably not requested. Confirm the job sets"
      echo "       EXTRA_NETWORK_CONFIG with a name and a <NAME>_NETWORK_SUBNET_V4 for every"
      echo "       subnet listed here, and that baremetalds-devscripts-conf-extranetwork ran"
      echo "       before dev-scripts provisioned the hosts."
      guest debug -n default "node/${node}" --quiet -- chroot /host ip -o addr show || true
      exit 1
    fi
    echo "  ${node}: ${iface}"
    if [[ -z "${found_iface}" ]]; then
      found_iface="${iface}"
    elif [[ "${found_iface}" != "${iface}" ]]; then
      echo "ERROR: interface name differs across nodes (${found_iface} vs ${iface} on ${node})."
      echo "       A single Tuned profile cannot cover both; aborting rather than half-configuring."
      exit 1
    fi
  done
  IFACES+=("${found_iface}")
done

# Two networks landing on one NIC would mean the discovery matched the same link twice,
# and everything downstream - the per-link routing tables OVN-Kubernetes builds, the
# per-interface SNAT rules - assumes they are distinct.
if [[ "${#IFACES[@]}" -gt 1 && "${IFACES[0]}" == "${IFACES[1]}" ]]; then
  echo "ERROR: both secondary subnets resolved to ${IFACES[0]}. They must be on separate NICs."
  exit 1
fi

for i in "${!IFACES[@]}"; do
  echo "Secondary interface $((i + 1)): ${IFACES[$i]} on ${SUBNETS[$i]}"
done

#
# 2. Global IP forwarding. The default of Restricted sets the kernel FORWARD policy to
#    DROP and only allows traffic OVN-Kubernetes itself needs. Pod traffic entering on
#    ovn-k8s-mp0 and leaving on a secondary NIC is not in that allowlist.
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
# 3. Per-interface forwarding sysctl, delivered by the Node Tuning Operator, for every
#    secondary NIC. ipForwarding: Global only changes the netfilter FORWARD policy;
#    OVN-Kubernetes sets net.ipv4.conf.<iface>.forwarding only on br-ex and ovn-k8s-mp0,
#    never on a NIC it does not manage. rp_filter is relaxed to loose mode so replies
#    arriving on a secondary NIC survive the reverse-path check, whose main-table lookup
#    points at br-ex. With more than one secondary NIC loose mode also stops replies being
#    dropped when the main-table best path for a destination is out of the sibling NIC.
#    On HyperShift a Tuned object reaches guest nodes through NodePool.spec.tuningConfig.
#
NODEPOOLS="$(mgmt get nodepool -n "${HYPERSHIFT_NAMESPACE}" \
  -o jsonpath="{range .items[?(@.spec.clusterName=='${CLUSTER_NAME}')]}{.metadata.name}{'\n'}{end}")"
if [[ -z "${NODEPOOLS}" ]]; then
  echo "ERROR: no NodePool found for HostedCluster ${CLUSTER_NAME} in ${HYPERSHIFT_NAMESPACE}"
  exit 1
fi
echo "NodePools: $(echo "${NODEPOOLS}" | tr '\n' ' ')"

# Ten spaces of indent puts these inside the Tuned profile's [sysctl] block once the
# heredoc below interpolates them.
sysctl_lines=""
for iface in "${IFACES[@]}"; do
  sysctl_lines+="          net.ipv4.conf.${iface}.forwarding=1"$'\n'
  sysctl_lines+="          net.ipv4.conf.${iface}.rp_filter=2"$'\n'
done
sysctl_lines="${sysctl_lines%$'\n'}"

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
          summary=Enable forwarding on the EgressIP secondary interfaces
          include=openshift-node
          [sysctl]
${sysctl_lines}
      recommend:
      - priority: 20
        profile: egressip-multinic
EOF

for np in ${NODEPOOLS}; do
  echo "Attaching ${TUNED_CONFIGMAP_NAME} to NodePool ${np}..."
  mgmt patch nodepool -n "${HYPERSHIFT_NAMESPACE}" "${np}" --type=merge -p \
    "{\"spec\":{\"tuningConfig\":[{\"name\":\"${TUNED_CONFIGMAP_NAME}\"}]}}"
done

echo "Waiting for the sysctls to land on every guest node..."
for node in ${NODES}; do
  for iface in "${IFACES[@]}"; do
    ok=""
    for _ in $(seq 1 30); do
      value="$(guest debug -n default "node/${node}" --quiet -- \
        chroot /host sysctl -n "net.ipv4.conf.${iface}.forwarding" 2>/dev/null | tr -d '[:space:]')" || true
      if [[ "${value}" == "1" ]]; then
        ok="yes"
        break
      fi
      sleep 10
    done
    if [[ -z "${ok}" ]]; then
      echo "ERROR: net.ipv4.conf.${iface}.forwarding is not 1 on ${node}"
      guest get pods -n openshift-cluster-node-tuning-operator || true
      exit 1
    fi
    echo "  ${node}: ${iface} forwarding=1"
  done
done

#
# 4. Stop the secondary NICs from installing competing default routes.
#    Each extra libvirt network is forward_mode=nat, so its dnsmasq hands out DHCP
#    option 3 pointing at the bridge address. Without this the node ends up with several
#    default routes and the winner depends on NetworkManager's metric assignment - and
#    with two extra networks there are three candidates, not two.
#    This is a runtime fix appropriate for CI. The supported production equivalent is
#    day-1 NIC configuration (NMStateConfig on the InfraEnv, or a MachineConfig
#    NetworkManager keyfile in NodePool.spec.config); Red Hat does not support
#    configuring a NIC post-installation on an OVN-Kubernetes cluster.
#
if [[ "${EGRESSIP_SECONDARY_NEVER_DEFAULT}" == "true" ]]; then
  for node in ${NODES}; do
    for iface in "${IFACES[@]}"; do
      echo "Setting ipv4.never-default on ${iface} (${node})..."
      guest debug -n default "node/${node}" --quiet -- chroot /host bash -c "
        set -e
        conn=\$(nmcli -g GENERAL.CONNECTION device show ${iface})
        if [[ -z \"\${conn}\" || \"\${conn}\" == '--' ]]; then
          echo 'no active NetworkManager connection on ${iface}'
          exit 1
        fi
        nmcli connection modify \"\${conn}\" ipv4.never-default yes
        nmcli device reapply ${iface} || nmcli connection up \"\${conn}\"
      "
    done
  done

  echo "Verifying the only default route is via br-ex on every node..."
  for node in ${NODES}; do
    routes="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -4 route show default 2>/dev/null)" || true
    echo "  ${node}: $(echo "${routes}" | tr '\n' '|')"
    for iface in "${IFACES[@]}"; do
      if echo "${routes}" | grep -q "dev ${iface}"; then
        echo "ERROR: ${node} still has a default route via ${iface}"
        exit 1
      fi
    done
  done
fi

#
# 5. Route to the echo server's off-subnet address, one per secondary interface.
#
#    This route is what the whole exercise turns on. OVN-Kubernetes builds a
#    secondary-host-network EgressIP's routing table by copying routes out of that link
#    from MAIN, filtered on output interface (generateRoutesForLink in
#    pkg/node/controllers/egressip/egressip.go), and synthesises a next-hopless
#    "default dev <iface>" when nothing gatewayed was copied. So every interface that is
#    expected to carry an EgressIP needs its own route to the target in main. A specific
#    prefix rather than a default, so it never competes with the default route via br-ex.
#
#    Both interfaces need to reach the SAME target for the test to mean anything, and the
#    kernel refuses two routes for one prefix at the same metric - so each slot gets a
#    distinct metric. They coexist in main, the lowest metric wins for the node's own
#    traffic, and the per-link filter still hands each EgressIP table its own copy.
#
#    Slot 1 is skipped when EGRESSIP_VLAN_ID is set: the egress path there is the tagged
#    subinterface, and hypershift-agent-ovn-egressip-multinic-vlan writes the route on it.
#    Slot 2 is untagged in both topologies and is always written here.
#
#    ipv4.routes is assigned rather than appended (+ipv4.routes) so a rerun against a warm
#    node does not accumulate duplicates.
#
if [[ -n "${EGRESSIP_REMOTE_SUBNET}" ]]; then
  for i in "${!IFACES[@]}"; do
    iface="${IFACES[$i]}"
    slot=$((i + 1))

    if [[ "${slot}" -eq 1 && -n "${EGRESSIP_VLAN_ID}" ]]; then
      echo "EGRESSIP_VLAN_ID=${EGRESSIP_VLAN_ID} is set; the VLAN step owns the"
      echo "${EGRESSIP_REMOTE_SUBNET} route for slot 1. Not adding it on ${iface}."
      continue
    fi

    # Default next hop is the extra network's libvirt bridge on the dev-scripts host,
    # which is also where the echo server's off-subnet address lives.
    if [[ "${slot}" -eq 1 ]]; then
      gateway="${EGRESSIP_REMOTE_GATEWAY:-${PREFIXES[$i]}1}"
    else
      gateway="${EGRESSIP_REMOTE_GATEWAY_2:-${PREFIXES[$i]}1}"
    fi
    metric=$((EGRESSIP_REMOTE_ROUTE_METRIC_BASE + (i * 100)))

    for node in ${NODES}; do
      echo "Adding ${EGRESSIP_REMOTE_SUBNET} via ${gateway} on ${iface} metric ${metric} (${node})..."
      guest debug -n default "node/${node}" --quiet -- chroot /host bash -c "
        set -e
        conn=\$(nmcli -g GENERAL.CONNECTION device show ${iface})
        if [[ -z \"\${conn}\" || \"\${conn}\" == '--' ]]; then
          echo 'no active NetworkManager connection on ${iface}'
          exit 1
        fi
        nmcli connection modify \"\${conn}\" ipv4.routes '${EGRESSIP_REMOTE_SUBNET} ${gateway} ${metric}'
        nmcli device reapply ${iface} || nmcli connection up \"\${conn}\"
      "
    done

    echo "Verifying the ${iface} route landed in main on every node..."
    for node in ${NODES}; do
      route="$(guest debug -n default "node/${node}" --quiet -- \
        chroot /host ip -4 route show "${EGRESSIP_REMOTE_SUBNET}" dev "${iface}" 2>/dev/null | tr -d '\r')" || true
      echo "  ${node}: ${route:-<none>}"
      if ! echo "${route}" | grep -q "via ${gateway}"; then
        echo "ERROR: ${node} has no route to ${EGRESSIP_REMOTE_SUBNET} via ${gateway} on ${iface}."
        echo "       An EgressIP on that interface would blackhole every off-subnet"
        echo "       destination, because ovnkube-node has nothing in main to copy."
        guest debug -n default "node/${node}" --quiet -- chroot /host ip -4 route show || true
        exit 1
      fi
    done
  done
fi

#
# 6. Confirm OVN-Kubernetes now considers every secondary subnet eligible. The
#    cluster-manager in the hosted control plane picks egress nodes purely from this
#    annotation, so if a subnet is missing here no EgressIP from it will ever be assigned.
#
echo "Checking k8s.ovn.org/host-cidrs..."
for node in ${NODES}; do
  for i in "${!PREFIXES[@]}"; do
    prefix="${PREFIXES[$i]}"
    ok=""
    for _ in $(seq 1 18); do
      cidrs="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' || true)"
      if [[ "${cidrs}" == *"${prefix}"* ]]; then
        ok="yes"
        break
      fi
      sleep 10
    done
    if [[ -z "${ok}" ]]; then
      echo "ERROR: ${node} host-cidrs does not advertise ${SUBNETS[$i]}: ${cidrs:-<empty>}"
      exit 1
    fi
  done
  echo "  ${node}: ${cidrs}"
done

#
# 7. Publish what we found. Addresses come from libvirt DHCP reservations allocated in
#    flavor-iteration order, not hostname order, so downstream tests must read them from
#    here (or from the node annotation) instead of hardcoding.
#
#    Slot 1 keeps the unsuffixed names it has always had, so a job or test that knows
#    about only one secondary interface is unaffected. Slot 2, when present, is published
#    alongside under a _2 suffix.
#
write_slot_outputs() {
  local suffix="$1" iface="$2" subnet="$3" prefix="$4" node addr

  echo "${iface}"  > "${SHARED_DIR}/egressip_secondary_iface${suffix}"
  echo "${subnet}" > "${SHARED_DIR}/egressip_secondary_subnet${suffix}"
  : > "${SHARED_DIR}/egressip_secondary_node_ips${suffix}"
  for node in ${NODES}; do
    addr="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' \
      | tr -d '[]"' | tr ',' '\n' | grep "^${prefix}" | head -1)" || true
    echo "${node} ${addr}" >> "${SHARED_DIR}/egressip_secondary_node_ips${suffix}"
  done
}

write_slot_outputs "" "${IFACES[0]}" "${SUBNETS[0]}" "${PREFIXES[0]}"
echo "************ ${IFACES[0]} ready on ${SUBNETS[0]} ************"
cat "${SHARED_DIR}/egressip_secondary_node_ips"

if [[ "${#IFACES[@]}" -gt 1 ]]; then
  write_slot_outputs "_2" "${IFACES[1]}" "${SUBNETS[1]}" "${PREFIXES[1]}"
  echo "************ ${IFACES[1]} ready on ${SUBNETS[1]} ************"
  cat "${SHARED_DIR}/egressip_secondary_node_ips_2"
fi
