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

# Wait for ovnkube-node pods to stabilize after MCP rollout, then verify
# at least one is ready before probing container names.
sleep 15
oc wait pod -n "${namespace}" -l app=ovnkube-node --for=condition=Ready --timeout=5m

first_ovn_pod=$(oc get pods -n "${namespace}" -l app=ovnkube-node \
  --field-selector status.phase=Running \
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
# Iterate by node and look up the current ovnkube-node pod for each node to
# avoid stale pod references after MCP rolling restarts.
# ---------------------------------------------------------------------------
readarray -t nodes < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for node_name in "${nodes[@]}"; do
  # Look up the current ovnkube-node pod on this node, with retry in case
  # the pod is being replaced after MCP rollout.
  pod_name=""
  for attempt in 1 2 3 4 5; do
    pod_name=$(oc get pods -n "${namespace}" -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node_name},status.phase=Running" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pod_name}" ]]; then
      break
    fi
    echo "  waiting for ovnkube-node pod on ${node_name} (attempt ${attempt}/5)..."
    sleep 10
  done
  if [[ -z "${pod_name}" ]]; then
    echo "  WARNING: no running ovnkube-node pod found on ${node_name}, skipping"
    continue
  fi
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

# ---------------------------------------------------------------------------
# Cross-subnet routing: each management node routes traffic between the
# secondary network (e.g. 192.168.221.0/24 on br-localnet) and the primary
# management network (e.g. 192.168.111.0/24 on br-ex).  The hypervisor
# (libvirt host) does NOT forward between its bridges, so each node acts as
# its own gateway.
#
# Required fixes:
# 1. rp_filter=2 (loose) — strict reverse-path filtering drops packets from
#    the secondary subnet arriving on br-ex because the reverse route goes
#    via the secondary bridge.
# 2. MASQUERADE — source-NAT traffic from the secondary subnet going out
#    br-ex.  Return traffic then arrives back at this node.
# ---------------------------------------------------------------------------
if [[ "${ENABLE_FORWARDING}" == "true" ]]; then
  echo ""
  echo "Configuring cross-subnet routing on each node..."

  routing_setup_b64=$(base64 -w0 <<'ROUTING_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
bridge="$1"
subnet="$2"

sysctl -w "net.ipv4.conf.br-ex.rp_filter=2" >/dev/null
sysctl -w "net.ipv4.conf.${bridge}.rp_filter=2" >/dev/null
sysctl -w "net.ipv4.conf.all.rp_filter=0" >/dev/null
echo "  rp_filter: loose mode on br-ex and ${bridge}"

if ! iptables -t nat -C POSTROUTING -s "${subnet}" -o br-ex -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${subnet}" -o br-ex -j MASQUERADE
  echo "  MASQUERADE: added ${subnet} -> br-ex"
else
  echo "  MASQUERADE: rule already exists"
fi
ROUTING_SCRIPT_EOF
  )

  for node_name in "${nodes[@]}"; do
    echo "  ${node_name}:"
    routing_ok=false
    for attempt in 1 2 3; do
      if oc debug "node/${node_name}" -n default --quiet=true -- chroot /host bash -c \
        "echo '${routing_setup_b64}' | base64 -d | bash -s -- '${LOCALNET_SECONDARY_BRIDGE}' '${LOCALNET_SECONDARY_SUBNET}'"
      then
        routing_ok=true
        break
      fi
      echo "    oc debug failed (attempt ${attempt}/3), retrying..." >&2
      sleep 5
    done
    if [[ "${routing_ok}" != "true" ]]; then
      echo "WARNING: routing setup failed on ${node_name}" >&2
    fi
  done
  echo "Cross-subnet routing configured"
fi

# ---------------------------------------------------------------------------
# When LOCALNET_SECONDARY_DNSMASQ_ENABLED=true, deploy dnsmasq on br-localnet
# on each management node to provide DHCP to guest VMs.
#
# With subnet-less NADs (LOCALNET_MULTI_DHCP_MODE=external in the create step),
# KubeVirt does not run its internal DHCP server because the pod interface has
# no IP. An external DHCP source is required. Each node runs its own dnsmasq
# instance with a partitioned DHCP range to avoid IP conflicts on the shared L2
# segment (all nodes' secondary NICs share the same libvirt network).
# ---------------------------------------------------------------------------
if [[ "${LOCALNET_SECONDARY_DNSMASQ_ENABLED:-false}" == "true" ]]; then
  echo ""
  echo "Setting up dnsmasq on ${LOCALNET_SECONDARY_BRIDGE} on each node..."

  DNSMASQ_GATEWAY="${LOCALNET_SECONDARY_DNSMASQ_GATEWAY:-auto}"
  DNSMASQ_DNS="${LOCALNET_SECONDARY_DNSMASQ_DNS:?required when DNSMASQ_ENABLED=true}"
  DNSMASQ_RANGE_START="${LOCALNET_SECONDARY_DNSMASQ_RANGE_START:?required when DNSMASQ_ENABLED=true}"
  DNSMASQ_RANGE_END="${LOCALNET_SECONDARY_DNSMASQ_RANGE_END:?required when DNSMASQ_ENABLED=true}"

  ip_to_int() {
    local IFS='.'
    read -r a b c d <<< "$1"
    echo $(( a * 16777216 + b * 65536 + c * 256 + d ))
  }
  int_to_ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
  }

  start_int=$(ip_to_int "${DNSMASQ_RANGE_START}")
  end_int=$(ip_to_int "${DNSMASQ_RANGE_END}")
  node_count=${#nodes[@]}
  total_ips=$(( end_int - start_int + 1 ))
  range_per_node=$(( total_ips / node_count ))

  echo "  DHCP gateway:    ${DNSMASQ_GATEWAY}"
  echo "  DHCP DNS:        ${DNSMASQ_DNS}"
  echo "  DHCP pool:       ${DNSMASQ_RANGE_START} - ${DNSMASQ_RANGE_END} (${total_ips} IPs)"
  echo "  Nodes:           ${node_count} (${range_per_node} IPs/node)"

  # Base64-encoded setup script run inside chroot /host on each node.
  # Configures dnsmasq as a systemd service that provides DHCP-only (port=0)
  # on the secondary OVS bridge.  Also blocks the hypervisor's competing DHCP
  # server via an OVS flow rule and auto-detects the gateway when set to "auto".
  dnsmasq_setup_b64=$(base64 -w0 <<'DNSMASQ_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
bridge="$1"
range_start="$2"
range_end="$3"
gateway="$4"
dns_server="$5"
conf="/etc/dnsmasq.d/localnet-secondary.conf"
pidfile="/run/localnet-secondary-dnsmasq.pid"
unit="/etc/systemd/system/localnet-secondary-dnsmasq.service"

if ! ip link show "${bridge}" &>/dev/null; then
  echo "Bridge ${bridge} not present on this node; skipping dnsmasq"
  exit 0
fi

# Auto-detect gateway: use the node's own bridge IP.  Traffic to management
# VIPs (API, ingress) is delivered locally via the kernel's local routing
# table; other management-network traffic goes via br-ex with MASQUERADE.
if [[ "${gateway}" == "auto" ]]; then
  gateway=$(ip -o -4 addr show dev "${bridge}" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [[ -z "${gateway}" ]]; then
    echo "ERROR: could not auto-detect gateway on ${bridge}"
    exit 1
  fi
  echo "Auto-detected gateway: ${gateway}"
fi

# Block competing DHCP from the hypervisor's dnsmasq / libvirt by dropping
# DHCP server responses (UDP src=67 dst=68) arriving from the physical NIC
# port on the OVS bridge.  Management nodes have static IPs, so this only
# prevents the hypervisor from racing with our dnsmasq for guest VM DHCP.
nic_port=$(ovs-vsctl list-ports "${bridge}" 2>/dev/null | head -1)
if [[ -n "${nic_port}" ]]; then
  nic_ofport=$(ovs-vsctl get Interface "${nic_port}" ofport 2>/dev/null || echo "")
  if [[ -n "${nic_ofport}" && "${nic_ofport}" != "-1" ]]; then
    ovs-ofctl add-flow "${bridge}" \
      "priority=100,udp,in_port=${nic_ofport},tp_src=67,tp_dst=68,actions=drop"
    echo "Blocked hypervisor DHCP on ${bridge} (NIC=${nic_port}, ofport=${nic_ofport})"
  else
    echo "WARNING: could not determine ofport for ${nic_port}, hypervisor DHCP not blocked"
  fi
else
  echo "WARNING: no NIC port found on ${bridge}, hypervisor DHCP not blocked"
fi

mkdir -p /etc/dnsmasq.d
cat > "${conf}" <<CONF
# DHCP-only server for KubeVirt guest VMs on the secondary localnet bridge.
# DNS is disabled (port=0) — VMs use the DNS server from dhcp-option 6.
interface=${bridge}
bind-interfaces
port=0
dhcp-range=${range_start},${range_end},255.255.255.0,12h
dhcp-option=3,${gateway}
dhcp-option=6,${dns_server}
log-dhcp
CONF

cat > "${unit}" <<UNIT
[Unit]
Description=Localnet secondary bridge DHCP on ${bridge}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${pidfile}
ExecStart=/usr/sbin/dnsmasq --conf-file=${conf} --pid-file=${pidfile}
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

/usr/sbin/dnsmasq --test --conf-file="${conf}"

systemctl stop localnet-secondary-dnsmasq.service 2>/dev/null || true
pkill -f "localnet-secondary.conf" 2>/dev/null || true
rm -f "${pidfile}"
systemctl reset-failed localnet-secondary-dnsmasq.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now localnet-secondary-dnsmasq.service

if ! systemctl is-active --quiet localnet-secondary-dnsmasq.service; then
  echo "localnet-secondary-dnsmasq.service failed to start"
  systemctl status localnet-secondary-dnsmasq.service --no-pager || true
  journalctl -u localnet-secondary-dnsmasq.service -n 20 --no-pager || true
  exit 1
fi

if ! ss -ulnp | grep -q ":67 "; then
  echo "dnsmasq is not listening for DHCP on port 67"
  journalctl -u localnet-secondary-dnsmasq.service -n 20 --no-pager || true
  exit 1
fi

echo "dnsmasq configured on ${bridge} (DHCP ${range_start}-${range_end}, gw=${gateway}, dns=${dns_server})"
DNSMASQ_SCRIPT_EOF
  )

  node_index=0
  for node_name in "${nodes[@]}"; do
    node_start_int=$(( start_int + node_index * range_per_node ))
    if [[ ${node_index} -eq $((node_count - 1)) ]]; then
      node_end_int=${end_int}
    else
      node_end_int=$(( node_start_int + range_per_node - 1 ))
    fi
    node_start=$(int_to_ip ${node_start_int})
    node_end=$(int_to_ip ${node_end_int})

    echo "  ${node_name}: DHCP range ${node_start} - ${node_end}"

    dnsmasq_ok=false
    for attempt in 1 2 3; do
      if oc debug "node/${node_name}" -n default --quiet=true -- chroot /host bash -c \
        "echo '${dnsmasq_setup_b64}' | base64 -d | bash -s -- '${LOCALNET_SECONDARY_BRIDGE}' '${node_start}' '${node_end}' '${DNSMASQ_GATEWAY}' '${DNSMASQ_DNS}'"
      then
        echo "  ${node_name}: dnsmasq configured"
        dnsmasq_ok=true
        break
      fi
      echo "  ${node_name}: oc debug failed (attempt ${attempt}/3), retrying in 10s..." >&2
      sleep 10
    done
    if [[ "${dnsmasq_ok}" != "true" ]]; then
      echo "ERROR: dnsmasq configuration failed on ${node_name}" >&2
      exit 1
    fi

    node_index=$((node_index + 1))
  done
  echo "dnsmasq setup complete on all ${node_count} nodes"
fi
