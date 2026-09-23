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
EGRESS_SUBNET_PREFIX="${EGRESSIP_SECONDARY_SUBNET%.*/*}."

echo "Guest cluster: ${CLUSTER_NAME}, secondary subnet: ${EGRESSIP_SECONDARY_SUBNET}"

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

EGRESS_IFACE=""
for node in ${NODES}; do
  echo "Looking for an address in ${EGRESS_SUBNET_PREFIX}0/24 on ${node}..."
  iface=""
  for _ in $(seq 1 30); do
    iface="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -o -4 addr show 2>/dev/null \
      | awk -v pfx="${EGRESS_SUBNET_PREFIX}" '$4 ~ "^"pfx {print $2; exit}')" || true
    [[ -n "${iface}" ]] && break
    sleep 10
  done
  if [[ -z "${iface}" ]]; then
    echo "ERROR: ${node} has no address in ${EGRESSIP_SECONDARY_SUBNET}."
    echo "       The extra libvirt network was probably not requested. Confirm the job sets"
    echo "       EXTRA_NETWORK_CONFIG and that baremetalds-devscripts-conf-extranetwork ran"
    echo "       before dev-scripts provisioned the hosts."
    guest debug -n default "node/${node}" --quiet -- chroot /host ip -o addr show || true
    exit 1
  fi
  echo "  ${node}: ${iface}"
  if [[ -z "${EGRESS_IFACE}" ]]; then
    EGRESS_IFACE="${iface}"
  elif [[ "${EGRESS_IFACE}" != "${iface}" ]]; then
    echo "ERROR: interface name differs across nodes (${EGRESS_IFACE} vs ${iface} on ${node})."
    echo "       A single Tuned profile cannot cover both; aborting rather than half-configuring."
    exit 1
  fi
done
echo "Secondary interface: ${EGRESS_IFACE}"

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
if [[ "${EGRESSIP_SECONDARY_NEVER_DEFAULT}" == "true" ]]; then
  for node in ${NODES}; do
    echo "Setting ipv4.never-default on ${EGRESS_IFACE} (${node})..."
    guest debug -n default "node/${node}" --quiet -- chroot /host bash -c "
      set -e
      conn=\$(nmcli -g GENERAL.CONNECTION device show ${EGRESS_IFACE})
      if [[ -z \"\${conn}\" || \"\${conn}\" == '--' ]]; then
        echo 'no active NetworkManager connection on ${EGRESS_IFACE}'
        exit 1
      fi
      nmcli connection modify \"\${conn}\" ipv4.never-default yes
      nmcli device reapply ${EGRESS_IFACE} || nmcli connection up \"\${conn}\"
    "
  done

  echo "Verifying a single default route per node..."
  for node in ${NODES}; do
    routes="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -4 route show default 2>/dev/null)" || true
    echo "  ${node}: $(echo "${routes}" | tr '\n' '|')"
    if echo "${routes}" | grep -q "dev ${EGRESS_IFACE}"; then
      echo "ERROR: ${node} still has a default route via ${EGRESS_IFACE}"
      exit 1
    fi
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
    echo "ERROR: ${node} host-cidrs does not advertise ${EGRESSIP_SECONDARY_SUBNET}: ${cidrs:-<empty>}"
    exit 1
  fi
  echo "  ${node}: ${cidrs}"
done

#
# 6. Publish what we found. Addresses come from libvirt DHCP reservations allocated in
#    flavor-iteration order, not hostname order, so downstream tests must read them from
#    here (or from the node annotation) instead of hardcoding.
#
echo "${EGRESS_IFACE}" > "${SHARED_DIR}/egressip_secondary_iface"
echo "${EGRESSIP_SECONDARY_SUBNET}" > "${SHARED_DIR}/egressip_secondary_subnet"
: > "${SHARED_DIR}/egressip_secondary_node_ips"
for node in ${NODES}; do
  addr="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' \
    | tr -d '[]"' | tr ',' '\n' | grep "^${EGRESS_SUBNET_PREFIX}" | head -1)" || true
  echo "${node} ${addr}" >> "${SHARED_DIR}/egressip_secondary_node_ips"
done

echo "************ Guest cluster ready for EgressIP on ${EGRESS_IFACE} ************"
cat "${SHARED_DIR}/egressip_secondary_node_ips"
