#!/bin/bash

set -euo pipefail

echo "************ hypershift-kubevirt localnet secondary bridge ************"

LOCALNET_SECONDARY_SUBNET="${LOCALNET_SECONDARY_SUBNET:?LOCALNET_SECONDARY_SUBNET is required}"
LOCALNET_SECONDARY_BRIDGE="${LOCALNET_SECONDARY_BRIDGE:-br-localnet}"
LOCALNET_SECONDARY_PHYSNET="${LOCALNET_SECONDARY_PHYSNET:-physnet-localnet}"
ENABLE_FORWARDING="${LOCALNET_SECONDARY_ENABLE_FORWARDING:-true}"

subnet_base="${LOCALNET_SECONDARY_SUBNET%%/*}"
subnet_prefix="${subnet_base%.*}."
escaped_prefix=$(printf '%s' "${subnet_prefix}" | sed 's/\./\\./g')

echo "Secondary subnet:  ${LOCALNET_SECONDARY_SUBNET}"
echo "Interface prefix:  ${subnet_prefix}*"
echo "OVS bridge:        ${LOCALNET_SECONDARY_BRIDGE}"
echo "OVN physnet:       ${LOCALNET_SECONDARY_PHYSNET}"
echo "Global forwarding: ${ENABLE_FORWARDING}"

# ---------------------------------------------------------------------------
# Enable global IP forwarding so management nodes route between the secondary
# network and the primary (management) network.
# ---------------------------------------------------------------------------
if [[ "${ENABLE_FORWARDING}" == "true" ]]; then
  current_fwd=$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}' 2>/dev/null || true)
  if [[ "${current_fwd}" != "Global" ]]; then
    echo ""
    echo "Enabling global IP forwarding (current: ${current_fwd:-Restricted})..."
    oc patch network.operator cluster --type=merge \
      -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'
    echo "Waiting for machine config pool to reconcile..."
    sleep 30
    oc wait mcp master worker --for condition=Updating=False --timeout=30m 2>/dev/null || true
    oc wait mcp master worker --for condition=Updated --timeout=30m 2>/dev/null || true
    echo "Global IP forwarding enabled"
  else
    echo "Global IP forwarding already enabled"
  fi
fi

# ---------------------------------------------------------------------------
# Discover OVN container names from the first ovnkube-node pod.
# ---------------------------------------------------------------------------
namespace="openshift-ovn-kubernetes"
oc wait pod -n "${namespace}" -l app=ovnkube-node --for=condition=Ready --timeout=5m

first_ovn_pod=$(oc get pods -n "${namespace}" -l app=ovnkube-node \
  -o jsonpath='{.items[0].metadata.name}')
containers=$(oc get pod -n "${namespace}" "${first_ovn_pod}" \
  -o jsonpath='{.spec.containers[*].name}')

OVS_CONTAINER=""
for c in ovs-daemons ovnkube-node ovnkube-controller; do
  if [[ " ${containers} " == *" ${c} "* ]] && \
     oc exec -n "${namespace}" "${first_ovn_pod}" -c "${c}" -- \
       which ovs-vsctl >/dev/null 2>&1; then
    OVS_CONTAINER="${c}"
    break
  fi
done
if [[ -z "${OVS_CONTAINER}" ]]; then
  echo "ERROR: could not find a container with ovs-vsctl" >&2
  exit 1
fi

NET_CONTAINER=""
for c in ovnkube-controller ovnkube-node; do
  if [[ " ${containers} " == *" ${c} "* ]] && \
     oc exec -n "${namespace}" "${first_ovn_pod}" -c "${c}" -- \
       bash -c "ip -V" >/dev/null 2>&1; then
    NET_CONTAINER="${c}"
    break
  fi
done
if [[ -z "${NET_CONTAINER}" ]]; then
  NET_CONTAINER="${OVS_CONTAINER}"
fi

echo ""
echo "OVS container: ${OVS_CONTAINER}"
echo "Net container: ${NET_CONTAINER}"

# ---------------------------------------------------------------------------
# On each node: discover the secondary NIC, create an OVS bridge, attach the
# NIC, move the IP to the bridge, and add the bridge-mapping.
# ---------------------------------------------------------------------------
readarray -t ovnkube_pods < <(oc get pods -n "${namespace}" -l app=ovnkube-node \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for pod_name in "${ovnkube_pods[@]}"; do
  node_name=$(oc get pod -n "${namespace}" "${pod_name}" -o jsonpath='{.spec.nodeName}')
  echo ""
  echo "=== ${node_name} (${pod_name}) ==="

  # Discover the secondary interface by matching the extra-network subnet.
  secondary_record=$(oc exec -n "${namespace}" "${pod_name}" -c "${NET_CONTAINER}" -- \
    bash -c "ip -o -4 addr show scope global | awk '\$4 ~ /^${escaped_prefix}/ {print \$2, \$4; exit}'" 2>/dev/null || true)
  if [[ -z "${secondary_record}" ]]; then
    echo "  WARNING: no interface matching ${subnet_prefix}* found, skipping"
    continue
  fi

  secondary_iface=$(echo "${secondary_record}" | awk '{print $1}')
  secondary_cidr=$(echo "${secondary_record}" | awk '{print $2}')
  echo "  secondary NIC: ${secondary_iface} (${secondary_cidr})"

  # Create OVS bridge if it doesn't already exist.
  if oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
      ovs-vsctl br-exists "${LOCALNET_SECONDARY_BRIDGE}" 2>/dev/null; then
    echo "  bridge ${LOCALNET_SECONDARY_BRIDGE} already exists"
  else
    echo "  creating bridge ${LOCALNET_SECONDARY_BRIDGE}"
    oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
      ovs-vsctl --may-exist add-br "${LOCALNET_SECONDARY_BRIDGE}"
  fi

  # Attach the secondary NIC to the bridge.
  if oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
      ovs-vsctl list-ports "${LOCALNET_SECONDARY_BRIDGE}" 2>/dev/null | grep -qx "${secondary_iface}"; then
    echo "  ${secondary_iface} already on ${LOCALNET_SECONDARY_BRIDGE}"
  else
    echo "  attaching ${secondary_iface} to ${LOCALNET_SECONDARY_BRIDGE}"
    oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
      ovs-vsctl --may-exist add-port "${LOCALNET_SECONDARY_BRIDGE}" "${secondary_iface}"
  fi

  # Move the IP from the NIC to the bridge so the node keeps L3 reachability.
  has_ip_on_bridge=$(oc exec -n "${namespace}" "${pod_name}" -c "${NET_CONTAINER}" -- \
    bash -c "ip -o -4 addr show dev ${LOCALNET_SECONDARY_BRIDGE} 2>/dev/null | awk '\$4 ~ /^${escaped_prefix}/ {print \$4; exit}'" 2>/dev/null || true)
  if [[ -n "${has_ip_on_bridge}" ]]; then
    echo "  bridge already has IP ${has_ip_on_bridge}"
  else
    echo "  moving IP ${secondary_cidr} from ${secondary_iface} to ${LOCALNET_SECONDARY_BRIDGE}"
    oc exec -n "${namespace}" "${pod_name}" -c "${NET_CONTAINER}" -- \
      bash -c "
        ip addr del ${secondary_cidr} dev ${secondary_iface} 2>/dev/null || true
        ip addr add ${secondary_cidr} dev ${LOCALNET_SECONDARY_BRIDGE} 2>/dev/null || true
        ip link set ${LOCALNET_SECONDARY_BRIDGE} up
      "
  fi

  # Add bridge-mapping.
  current_mappings=$(oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
    ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null | tr -d '"' || true)
  if [[ -z "${current_mappings}" ]]; then
    current_mappings="physnet:br-ex"
  fi
  desired="${LOCALNET_SECONDARY_PHYSNET}:${LOCALNET_SECONDARY_BRIDGE}"
  if echo "${current_mappings}" | grep -q "${desired}"; then
    echo "  bridge-mapping already has ${desired}"
  else
    new_mappings="${current_mappings},${desired}"
    oc exec -n "${namespace}" "${pod_name}" -c "${OVS_CONTAINER}" -- \
      ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-mappings="${new_mappings}"
    echo "  bridge-mappings: ${new_mappings}"
  fi
done

echo ""
echo "Secondary localnet bridge setup complete"
echo "  bridge:  ${LOCALNET_SECONDARY_BRIDGE}"
echo "  physnet: ${LOCALNET_SECONDARY_PHYSNET}"
