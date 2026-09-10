#!/bin/bash

set -exuo pipefail

HCP_CLI="/usr/bin/hcp"

MCE=${MCE_VERSION:-""}
CLUSTER_NAME=$(echo -n "${PROW_JOB_ID}"|sha256sum|cut -c-20)
if [[ -n ${MCE} ]] ; then
    CLUSTER_NAMESPACE_PREFIX=local-cluster
else
    CLUSTER_NAMESPACE_PREFIX=clusters
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n ${MCE} ]] ; then
  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    downURL=$(oc get ConsoleCLIDownload hcp-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hcp CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/hcp.tar.gz" "${downURL}"
    cd /tmp && tar -xvf "/tmp/hcp.tar.gz"
    chmod +x "/tmp/hcp"
    HCP_CLI="/tmp/hcp"
    cd -
  fi
fi

function support_np_skew() {
  local EXTRA_FLARGS=""
  if [[ -n "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" && -n "$NODEPOOL_RELEASE_IMAGE_LATEST" && -n "$MCE" && "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" != "$NODEPOOL_RELEASE_IMAGE_LATEST" ]]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" -o /tmp/yq && chmod +x /tmp/yq
    # >= 2.7: "--render-sensitive --render", else: "--render"
    if [[ "$(printf '%s\n' "2.7" "$MCE_VERSION" | sort -V | head -n1)" == "2.7" ]]; then
      EXTRA_FLARGS+="--render-sensitive --render > /tmp/hc.yaml "
    else
      EXTRA_FLARGS+="--render > /tmp/hc.yaml "
    fi
    EXTRA_FLARGS+="&& /tmp/yq e -i '(select(.kind == \"NodePool\").spec.release.image) = \"$NODEPOOL_RELEASE_IMAGE_LATEST\"' /tmp/hc.yaml "
    EXTRA_FLARGS+="&& oc apply -f /tmp/hc.yaml"
  fi
  echo "$EXTRA_FLARGS"
}

# discover_ovn_container_names sets OVN_OVS_CONTAINER and OVN_NBDB_CONTAINER
# based on the containers available in the ovnkube-node pod.
# In OCP 4.17+ (INTERCONNECT mode), ovnkube-node container was replaced by ovnkube-controller.
discover_ovn_container_names() {
  local pod_name="$1"
  local containers

  containers=$(oc get pod -n openshift-ovn-kubernetes "${pod_name}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

  # Discover OVS container (for ovs-vsctl commands)
  for candidate in ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      OVN_OVS_CONTAINER="${candidate}"
      break
    fi
  done

  # Discover NBDB container (for ovn-nbctl commands)
  for candidate in nbdb ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      OVN_NBDB_CONTAINER="${candidate}"
      break
    fi
  done

  if [[ -z "${OVN_OVS_CONTAINER}" ]] || [[ -z "${OVN_NBDB_CONTAINER}" ]]; then
    echo "ERROR: unable to discover OVN containers in pod ${pod_name}" >&2
    echo "  Available containers: ${containers}" >&2
    return 1
  fi

  echo "INFO: Discovered OVN containers - OVS: ${OVN_OVS_CONTAINER}, NBDB: ${OVN_NBDB_CONTAINER}"
  return 0
}

# Attach OVN DHCP_Options to each passthrough localnet LSP and clear port_security.
# For subnets-less NADs (L2 passthrough), OVN's DHCP responder leases from the
# DHCP_Options cidr. For NADs with "subnets" (OVN IPAM), the same call hands out
# the pre-assigned address. Either way, VMs do not receive an IP until this runs.
configure_ovn_localnet_lsp_dhcp() {
  local target_ns="$1"
  local subnet_cidr="$2"
  local router_ip="$3"
  local dns_server="${4:-}"
  local node ovn_pod lsps lsp dhcp_uuid dhcp_opts

  if [[ -z "${OVN_NBDB_CONTAINER:-}" ]]; then
    discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
    if ! discover_ovn_container_names "${discovery_pod}"; then
      echo "ERROR: Failed to discover OVN container names" >&2
      return 1
    fi
  fi

  if [[ -n "${dns_server}" ]]; then
    dhcp_opts='"lease_time"="3500" "router"="'"${router_ip}"'" "server_id"="'"${router_ip}"'" "server_mac"="c0:ff:ee:00:00:01" "dns_server"="'"${dns_server}"'"'
  else
    dhcp_opts='"lease_time"="3500" "router"="'"${router_ip}"'" "server_id"="'"${router_ip}"'" "server_mac"="c0:ff:ee:00:00:01"'
  fi

  echo "Configuring OVN DHCP (${subnet_cidr}) on localnet LSPs in ${target_ns}..."
  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    ovn_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')
    [[ -z "${ovn_pod}" ]] && continue
    lsps=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl --bare --columns=name find Logical_Switch_Port \
        external_ids:namespace="${target_ns}" \
        external_ids:k8s.ovn.org/topology=localnet 2>/dev/null || true)
    for lsp in ${lsps}; do
      [[ -z "${lsp}" ]] && continue
      dhcp_uuid=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
        ovn-nbctl create DHCP_Options cidr="${subnet_cidr}" \
        options="${dhcp_opts}" 2>/dev/null)
      oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
        ovn-nbctl lsp-set-dhcpv4-options "${lsp}" "${dhcp_uuid}" 2>/dev/null
      oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
        ovn-nbctl clear Logical_Switch_Port "${lsp}" port_security 2>/dev/null || true
      echo "Configured OVN DHCP and cleared port security on ${lsp} (node ${node})"
    done
  done
}

# Clear port_security on passthrough localnet LSPs (EgressIP SNAT egress).
clear_ovn_localnet_lsp_port_security() {
  local target_ns="$1"
  local node ovn_pod lsps lsp

  if [[ -z "${OVN_NBDB_CONTAINER:-}" ]]; then
    discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
    if ! discover_ovn_container_names "${discovery_pod}"; then
      echo "ERROR: Failed to discover OVN container names" >&2
      return 1
    fi
  fi

  echo "Clearing port security on localnet LSPs in ${target_ns}..."
  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    ovn_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')
    [[ -z "${ovn_pod}" ]] && continue
    lsps=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl --bare --columns=name find Logical_Switch_Port \
        external_ids:namespace="${target_ns}" \
        external_ids:k8s.ovn.org/topology=localnet 2>/dev/null || true)
    for lsp in ${lsps}; do
      [[ -z "${lsp}" ]] && continue
      oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
        ovn-nbctl clear Logical_Switch_Port "${lsp}" port_security 2>/dev/null || true
      echo "Cleared port security on ${lsp} (node ${node})"
    done
  done
}

# Run dnsmasq on the VLAN sub-interface (e.g. br-ex.100) on each mgmt node before worker
# VMIs boot (localnet-vlan). br-localnet is an OVS bridge without a kernel netdev; the NNCP
# creates br-ex.<vlan-id> as the L2 port workers attach to. DHCP/DNS must be on that segment,
# not ostestbm br-ex (untagged 192.168.111.0/24).
localnet_vlan_configure_br_localnet_dhcp() {
  local cluster_name="$1"
  local vlan_id="$2"
  local dhcp_iface="$3"
  local gateway="$4"
  local dhcp_start="$5"
  local dhcp_end="$6"
  local ingress_vip="$7"
  local uplink_bond="$8"
  local base_domain
  local node
  local setup_b64

  base_domain=$(oc get dns/cluster -o jsonpath='{.spec.baseDomain}')
  echo "Configuring dnsmasq on ${dhcp_iface} for VLAN ${vlan_id} (cluster ${cluster_name}, DNS base ${base_domain})..."

  setup_b64=$(base64 -w0 <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
dhcp_iface="$1"
gateway="$2"
dhcp_start="$3"
dhcp_end="$4"
cluster_name="$5"
base_domain="$6"
ingress_vip="$7"
vlan_id="$8"
uplink_bond="$9"
netmask="255.255.255.0"
conf="/etc/dnsmasq.d/localnet-vlan-${vlan_id}.conf"
pidfile="/run/localnet-vlan-${vlan_id}.pid"

if ! ip link show "${dhcp_iface}" &>/dev/null; then
  echo "VLAN interface ${dhcp_iface} not present on this node; skipping"
  exit 0
fi

if [[ -f "${pidfile}" ]]; then
  kill "$(cat "${pidfile}")" 2>/dev/null || true
  rm -f "${pidfile}"
fi

ip link set "${dhcp_iface}" up
if ! ip addr show dev "${dhcp_iface}" | grep -q "inet ${gateway}/"; then
  ip addr add "${gateway}/24" dev "${dhcp_iface}"
fi

mkdir -p /etc/dnsmasq.d
cat > "${conf}" <<CONF
interface=${dhcp_iface}
bind-interfaces
except-interface=lo
port=5353
listen-address=${gateway}
domain-needed
bogus-priv
no-resolv
server=172.30.0.10
address=/api.${cluster_name}.${base_domain}/${ingress_vip}
address=/api-int.${cluster_name}.${base_domain}/${ingress_vip}
address=/.apps.${cluster_name}.${base_domain}/${ingress_vip}
dhcp-range=${dhcp_start},${dhcp_end},${netmask},12h
dhcp-option=3,${gateway}
dhcp-option=6,${gateway}
log-dhcp
CONF

sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -t nat -C PREROUTING -i "${dhcp_iface}" -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "${dhcp_iface}" -p udp --dport 53 -j REDIRECT --to-ports 5353
iptables -t nat -C PREROUTING -i "${dhcp_iface}" -p tcp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "${dhcp_iface}" -p tcp --dport 53 -j REDIRECT --to-ports 5353

iptables -C FORWARD -i "${dhcp_iface}" -o "${uplink_bond}" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "${dhcp_iface}" -o "${uplink_bond}" -j ACCEPT
iptables -C FORWARD -i "${uplink_bond}" -o "${dhcp_iface}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "${uplink_bond}" -o "${dhcp_iface}" -m state --state RELATED,ESTABLISHED -j ACCEPT

/usr/sbin/dnsmasq --conf-file="${conf}" --pid-file="${pidfile}"

if ! ss -ulnp | grep -q "${dhcp_iface}:67"; then
  echo "dnsmasq is not listening for DHCP on ${dhcp_iface}"
  exit 1
fi

echo "dnsmasq configured on ${dhcp_iface} (${gateway}, DHCP ${dhcp_start}-${dhcp_end})"
SCRIPT_EOF
)

  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "Setting up ${dhcp_iface} DHCP/DNS on node ${node}..."
    if ! oc debug "node/${node}" --quiet=true -- chroot /host bash -c \
      "echo '${setup_b64}' | base64 -d | bash -s -- '${dhcp_iface}' '${gateway}' '${dhcp_start}' '${dhcp_end}' '${cluster_name}' '${base_domain}' '${ingress_vip}' '${vlan_id}' '${uplink_bond}'"
    then
      echo "WARNING: failed to configure ${dhcp_iface} DHCP on node ${node}" >&2
      return 1
    fi
  done
}

localnet_multi_label_namespace_privileged() {
  local multi_ns="$1"

  oc label namespace "${multi_ns}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    security.openshift.io/scc.podSecurityLabelSync=false --overwrite 2>/dev/null || true
}

localnet_multi_prepare_ssh_key_secret() {
  local multi_ns="$1"
  local ssh_key_secret="${CLUSTER_NAME}-ssh-key"

  if ! oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_key_secret}" &>/dev/null; then
    echo "WARNING: SSH key secret ${ssh_key_secret} not found" >&2
    return 1
  fi

  oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_key_secret}" -o json \
    | python3 -c "import sys,json; s=json.load(sys.stdin); s['metadata']={'name':s['metadata']['name'],'namespace':'${multi_ns}'}; print(json.dumps(s))" \
    | oc apply -f - 2>/dev/null || true
  return 0
}

localnet_multi_vmi_primary_ipv4() {
  local multi_ns="$1"
  local vmi="$2"

  oc get vmi -n "${multi_ns}" "${vmi}" -o json | python3 -c '
import json
import re
import sys

vmi = json.load(sys.stdin)
for iface in vmi.get("status", {}).get("interfaces", []):
    ip = iface.get("ipAddress", "")
    if re.match(r"^\d+\.\d+\.\d+\.\d+", ip):
        print(ip.split()[0])
        sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

localnet_multi_ensure_bootstrap_ssh_pods() {
  local multi_ns="$1"
  local node pod_name ssh_image

  ssh_image="${LOCALNET_MULTI_SSH_POD_IMAGE:-registry.redhat.io/rhel9/support-tools:latest}"
  for node in $(oc get pods -n "${multi_ns}" -l kubevirt.io=virt-launcher \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u); do
    [[ -z "${node}" ]] && continue
    pod_name="kubelet-bootstrap-${node//./-}"
    if oc get pod -n "${multi_ns}" "${pod_name}" &>/dev/null; then
      continue
    fi
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${multi_ns}
  annotations:
    k8s.v1.cni.cncf.io/networks: localnet-1
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  restartPolicy: Never
  volumes:
  - name: ssh-key
    secret:
      secretName: ${CLUSTER_NAME}-ssh-key
      defaultMode: 384
  containers:
  - name: ssh
    image: ${ssh_image}
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: ssh-key
      mountPath: /ssh
EOF
  done

  for node in $(oc get pods -n "${multi_ns}" -l kubevirt.io=virt-launcher \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u); do
    [[ -z "${node}" ]] && continue
    pod_name="kubelet-bootstrap-${node//./-}"
    oc wait pod/"${pod_name}" -n "${multi_ns}" --for=condition=Ready --timeout=180s 2>/dev/null || {
      echo "WARNING: bootstrap SSH pod ${pod_name} not Ready on node ${node}" >&2
      return 1
    }
  done
  return 0
}

localnet_multi_start_guest_kubelet_if_needed() {
  local multi_ns="$1"
  local node="$2"
  local vmi_ip="$3"
  local vmi="$4"
  local pod_name="kubelet-bootstrap-${node//./-}"

  if ! oc exec -n "${multi_ns}" "${pod_name}" -c ssh -- bash -s -- "${vmi_ip}" "${vmi}" <<'EOF'
vmi_ip="$1"
vmi="$2"
KEY=/ssh/id_rsa
[[ -f "$KEY" ]] || KEY=/ssh/id_ed25519
chmod 600 "$KEY"
status=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
  "core@${vmi_ip}" systemctl is-active kubelet 2>/dev/null || echo inactive)
if [[ "$status" == "active" ]]; then
  exit 0
fi
echo "Starting crio and kubelet on ${vmi} (${vmi_ip})..."
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
  "core@${vmi_ip}" 'sudo systemctl start crio && sudo systemctl start kubelet'
EOF
  then
    echo "WARNING: kubelet bootstrap SSH failed for ${vmi} (${vmi_ip})" >&2
    return 1
  fi
  return 0
}

# Pick a Ready mgmt node without DiskPressure for the ip-echo pod. The blanket
# operator:Exists toleration would allow scheduling onto disk-pressured nodes and
# immediate eviction. Optional args: space-separated node names to skip on retry.
select_ipecho_node() {
  local exclude_nodes="${1:-}"
  if ! oc get nodes -o json | python3 -c "
import json, sys
exclude = set(filter(None, '''${exclude_nodes}'''.split()))
for node in json.load(sys.stdin)['items']:
    name = node['metadata']['name']
    if name in exclude:
        continue
    conditions = {c['type']: c['status'] for c in node.get('status', {}).get('conditions', [])}
    if conditions.get('Ready') != 'True':
        continue
    if conditions.get('DiskPressure') == 'True':
        continue
    print(name)
    sys.exit(0)
print('ERROR: no Ready node without DiskPressure for ip-echo', file=sys.stderr)
sys.exit(1)
"; then
    return 1
  fi
}

wait_for_ipecho_pod() {
  local namespace="${1}"
  local timeout_sec="${2:-120}"
  local phase reason

  if oc wait --for=condition=Ready pod/egressip-ipecho -n "${namespace}" --timeout="${timeout_sec}s"; then
    return 0
  fi

  phase=$(oc get pod egressip-ipecho -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  reason=$(oc get pod egressip-ipecho -n "${namespace}" -o jsonpath='{.status.reason}' 2>/dev/null || true)
  echo "ip-echo pod not Ready (phase=${phase}, reason=${reason})" >&2
  oc describe pod egressip-ipecho -n "${namespace}" 2>&1 | tail -20 >&2 || true
  return 1
}

# After workers join: clear OVN port security on all passthrough localnet LSPs (EgressIP
# SNAT) and enable forwarding on secondary virtio NICs inside guest ovn-kube-node pods.
configure_localnet_multi_egress_prereqs() {
  local multi_ns="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
  local network_count="${LOCALNET_MULTI_NETWORK_COUNT:-4}"
  local nested_kc="${SHARED_DIR}/nested_kubeconfig"
  local running_count node ovn_pod lsp lsps ovn_ready ovn_node_pod i

  if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
    discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
    if ! discover_ovn_container_names "${discovery_pod}"; then
      echo "ERROR: Failed to discover OVN container names" >&2
      return 1
    fi
  fi

  echo "Waiting for ${HYPERSHIFT_NODE_COUNT} worker VMIs before egress interface setup..."
  for _ in $(seq 1 60); do
    running_count=$(oc get vmi -n "${multi_ns}" --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "${running_count}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${running_count} worker VMIs are running"
      break
    fi
    echo "Waiting for VMIs... (${running_count}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  echo "Clearing port security on localnet-multi VM LSPs..."
  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    ovn_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')
    [[ -z "${ovn_pod}" ]] && continue
    lsps=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl --bare --columns=name find Logical_Switch_Port \
        external_ids:namespace="${multi_ns}" \
        external_ids:k8s.ovn.org/topology=localnet 2>/dev/null || true)
    for lsp in ${lsps}; do
      [[ -z "${lsp}" ]] && continue
      oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
        ovn-nbctl clear Logical_Switch_Port "${lsp}" port_security 2>/dev/null || true
      echo "Cleared port security on ${lsp} (hypervisor ${node})"
    done
  done

  if [[ ! -f "${nested_kc}" ]]; then
    echo "WARNING: Nested kubeconfig not found at ${nested_kc}; skipping secondary NIC forwarding"
    return 0
  fi

  echo "Waiting for guest OVN node pods..."
  for _ in $(seq 1 60); do
    ovn_ready=$(KUBECONFIG="${nested_kc}" oc get pods -n openshift-ovn-kubernetes \
      -l app=ovnkube-node --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "${ovn_ready}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${ovn_ready} guest OVN node pods are running"
      break
    fi
    echo "Waiting for guest OVN node pods... (${ovn_ready}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  echo "Enabling IP forwarding on secondary guest NICs enp2s0..enp${network_count}s0..."
  for ovn_node_pod in $(KUBECONFIG="${nested_kc}" oc get pods -n openshift-ovn-kubernetes \
    -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    for i in $(seq 2 "${network_count}"); do
      KUBECONFIG="${nested_kc}" oc exec -n openshift-ovn-kubernetes "${ovn_node_pod}" \
        -c "${OVN_OVS_CONTAINER}" -- sysctl -w "net.ipv4.conf.enp${i}s0.forwarding=1" 2>/dev/null || true
    done
    echo "Enabled secondary NIC forwarding on guest ${ovn_node_pod}"
  done
}

# Workers on localnet-multi can reach ignition/API via ostestbm DHCP, but kubelet may
# fail first boot when node-sizing.env is not ready and crio is still inactive. Poll
# worker VMIs over localnet-1 SSH and start crio/kubelet until the NodePool is Ready.
ensure_localnet_multi_worker_kubelet_started() {
  local multi_ns="$1"
  local deadline running_count vmi vmi_ip vmi_node

  if [[ "${LOCALNET_MULTI_ENABLE_KUBELET_BOOTSTRAP_ASSIST:-true}" != "true" ]]; then
    echo "Skipping localnet-multi kubelet bootstrap assist (LOCALNET_MULTI_ENABLE_KUBELET_BOOTSTRAP_ASSIST=false)"
    return 0
  fi

  deadline=$(($(date +%s) + ${LOCALNET_MULTI_KUBELET_BOOTSTRAP_TIMEOUT:-2700}))
  echo "Ensuring localnet-multi worker kubelet/crio are running (timeout ${LOCALNET_MULTI_KUBELET_BOOTSTRAP_TIMEOUT:-2700}s)..."

  localnet_multi_label_namespace_privileged "${multi_ns}"
  if ! localnet_multi_prepare_ssh_key_secret "${multi_ns}"; then
    return 1
  fi

  while [[ $(date +%s) -lt ${deadline} ]]; do
    if oc get nodepool "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      echo "NodePool is Ready"
      for pod in $(oc get pods -n "${multi_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        [[ "${pod}" == kubelet-bootstrap-* ]] && oc delete pod -n "${multi_ns}" "${pod}" --ignore-not-found 2>/dev/null || true
      done
      return 0
    fi

    running_count=$(oc get vmi -n "${multi_ns}" --no-headers 2>/dev/null \
      | awk '$3 ~ /Running/ {count++} END {print count+0}')
    if [[ ${running_count} -lt ${HYPERSHIFT_NODE_COUNT} ]]; then
      echo "Waiting for worker VMIs... (${running_count}/${HYPERSHIFT_NODE_COUNT} running)"
      sleep 15
      continue
    fi

    if ! localnet_multi_ensure_bootstrap_ssh_pods "${multi_ns}"; then
      sleep 15
      continue
    fi

    for vmi in $(oc get vmi -n "${multi_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      vmi_ip=$(localnet_multi_vmi_primary_ipv4 "${multi_ns}" "${vmi}")
      vmi_node=$(oc get vmi -n "${multi_ns}" "${vmi}" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
      [[ -z "${vmi_ip}" || -z "${vmi_node}" ]] && continue
      localnet_multi_start_guest_kubelet_if_needed "${multi_ns}" "${vmi_node}" "${vmi_ip}" "${vmi}" || true
    done

    echo "NodePool not Ready yet; retrying kubelet bootstrap assist in 30s..."
    sleep 30
  done

  echo "ERROR: timed out waiting for NodePool Ready during kubelet bootstrap assist" >&2
  return 1
}

if [[ ! -f $HCP_CLI ]]; then
  # we have to fall back to hypershift in cases where the new hcp cli isn't available yet
  HCP_CLI="/usr/bin/hypershift"
fi
echo "Using $HCP_CLI for cli"

RUN_HOSTEDCLUSTER_CREATION="${RUN_EXTERNAL_INFRA_TEST:-$RUN_HOSTEDCLUSTER_CREATION}"

if [ "${RUN_HOSTEDCLUSTER_CREATION}" != "true" ]
then
  echo "Creation of a kubevirt hosted cluster has been skipped."
  exit 0
fi


if [ -n "${KUBEVIRT_CSI_INFRA}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --infra-storage-class-mapping=${KUBEVIRT_CSI_INFRA}/${KUBEVIRT_CSI_INFRA}"
fi

if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "AWS" ]; then
  if [ -z "$ETCD_STORAGE_CLASS" ]; then
    echo "AWS infra detected. Setting --etcd-storage-class"
    ETCD_STORAGE_CLASS="gp3-csi"
  fi
fi

if [ -n "${ETCD_STORAGE_CLASS}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"
ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml")
  echo "extract secret/pull-secret"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  PULL_SECRET_PATH="/tmp/.dockerconfigjson"
  if [ ! -f /tmp/yq-v4 ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  fi
  oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > "${SHARED_DIR}/mgmt_icsp.yaml"
fi

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'


RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

if [[ "${DISCONNECTED}" == "true" ]];
then
  mirror_registry=$(oc get imagecontentsourcepolicy cnv-repo -o=jsonpath='{.spec.repositoryDigestMirrors[0].mirrors[0]}')
  mirror_registry=${mirror_registry%%/*}
  if [[ $mirror_registry == "" ]] ; then
      echo "Warning: Can not find the mirror registry, abort !!!"
      exit 1
  fi
  echo "mirror registry is ${mirror_registry}"

  OLM_CATALOGS_R_OVERRIDES=registry.redhat.io/redhat=${mirror_registry}/olm-index
  PAYLOADIMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
  RELEASE_IMAGE="${PAYLOADIMAGE}"

  if [ ! -f "${SHARED_DIR}/ho_operator_image" ] ; then
      echo "Warning: Can not find ho_operator_image, abort !!!"
      exit 1
  fi
  HO_OPERATOR_IMAGE=$(cat "${SHARED_DIR}/ho_operator_image")

  EXTRA_ARGS="${EXTRA_ARGS} --additional-trust-bundle=${SHARED_DIR}/registry.2.crt --annotations=hypershift.openshift.io/control-plane-operator-image=${HO_OPERATOR_IMAGE} --annotations=hypershift.openshift.io/olm-catalogs-is-registry-overrides=${OLM_CATALOGS_R_OVERRIDES}"

  ### workaround for https://issues.redhat.com/browse/OCPBUGS-32770
  if [[ -z ${MCE} ]] ; then
    if [ ! -f "${SHARED_DIR}/capi_provider_kubevirt_image" ] ; then
        echo "Warning: Can not find capi_provider_kubevirt_image, abort !!!"
        exit 1
    fi
    CAPI_PROVIDER_KUBEVIRT_IMAGE=$(cat "${SHARED_DIR}/capi_provider_kubevirt_image")

    EXTRA_ARGS="${EXTRA_ARGS} --annotations=hypershift.openshift.io/capi-provider-kubevirt-image=${CAPI_PROVIDER_KUBEVIRT_IMAGE}"
  fi
  ###

fi

oc create namespace "${CLUSTER_NAMESPACE_PREFIX}" --dry-run=client -o yaml | oc apply -f -
oc create ns "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
if [[ -n "${ATTACH_DEFAULT_NETWORK}" ]]; then
  if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet" ]]; then
    # Model 3: Localnet — VMs connect directly to physical network via OVN localnet.
    # The NAD config "name" must match an existing OVN bridge-mapping on the nodes.
    # OVN-Kubernetes automatically creates "physnet:br-ex" on all nodes, so we use
    # "physnet" as the network name to reuse that default mapping (no NNCP needed).
    # The "subnets" field enables OVN-managed IPAM so VMs get IPs automatically.
    # attach-default-network=true keeps the pod network for control plane traffic
    # (ignition, API server, konnectivity) while the localnet interface provides
    # direct L2 connectivity for data plane features like EgressIP.
    oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-network
  namespace: ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}/localnet-network",
      "subnets": "192.168.223.0/24"
  }'
EOF
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=true --additional-network name:${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}/localnet-network"
  elif [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
    # Multi-Network Localnet Architecture:
    # VMs get LOCALNET_MULTI_NETWORK_COUNT localnet interfaces with --attach-default-network=false
    # (no pod network). Every localnet NAD (localnet-1..N) is subnets-less L2 passthrough to br-ex;
    # OVN does not run IPAM/DHCP. Each virtio NIC (enp1s0..enpNs0) gets IPv4 via ostestbm
    # libvirt dnsmasq (192.168.111.1, pool .100-.240). Guest OVN uses enp1s0 as br-ex for the
    # default route; enp2s0.. carry additional addresses on the same L2 segment.

    ns="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
    NETWORK_COUNT="${LOCALNET_MULTI_NETWORK_COUNT:-2}"
    if [[ "${NETWORK_COUNT}" -lt 1 ]]; then
      echo "ERROR: LOCALNET_MULTI_NETWORK_COUNT must be at least 1"
      exit 1
    fi
    echo "Setting up ${NETWORK_COUNT} localnet networks (no pod network)..."

    # Discover OVN container names before first oc exec usage
    if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
      # Get first ovnkube-node pod for container discovery
      discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
      if ! discover_ovn_container_names "${discovery_pod}"; then
        echo "ERROR: Failed to discover OVN container names" >&2
        exit 1
      fi
    fi

    # Add physnet2..physnetN bridge-mappings on all nodes.
    # The default physnet:br-ex exists automatically. Additional bridge-mapping names
    # (physnet2, physnet3, ...) are needed because OVN-K doesn't support multiple NADs
    # with different configs on the same NetConf.Name. All map to the same physical bridge br-ex.
    if [[ ${NETWORK_COUNT} -gt 1 ]]; then
      echo "Adding physnet2..physnet${NETWORK_COUNT} bridge-mappings on all nodes..."
      for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
          --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')
        if [[ -z "${OVN_POD}" ]]; then
          echo "WARNING: No ovnkube-node pod found on node ${NODE}, skipping"
          continue
        fi
        CURRENT_MAPPINGS=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
          ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null | tr -d '"' || true)
        if [[ -z "${CURRENT_MAPPINGS}" ]]; then
          CURRENT_MAPPINGS="physnet:br-ex"
        fi
        NEW_MAPPINGS="${CURRENT_MAPPINGS}"
        for i in $(seq 2 "${NETWORK_COUNT}"); do
          if ! echo "${NEW_MAPPINGS}" | grep -q "physnet${i}:br-ex"; then
            NEW_MAPPINGS="${NEW_MAPPINGS},physnet${i}:br-ex"
          fi
        done
        if [[ "${NEW_MAPPINGS}" != "${CURRENT_MAPPINGS}" ]]; then
          oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
            ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-mappings="${NEW_MAPPINGS}" || true
          echo "Updated bridge-mappings on node ${NODE}: ${NEW_MAPPINGS}"
        else
          echo "Bridge-mappings already correct on node ${NODE}: ${CURRENT_MAPPINGS}"
        fi
      done

      # Verify bridge-mappings on all nodes
      echo "Verifying bridge-mappings on all nodes..."
      for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
          --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')
        MAPPINGS=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
          ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null || true)
        echo "  ${NODE}: ${MAPPINGS}"
      done
    fi

    # Create localnet NADs: all subnets-less passthrough (physnet/physnet2..N → br-ex).
    for i in $(seq 1 "${NETWORK_COUNT}"); do
      NAD_NAME="localnet-${i}"
      if [[ ${i} -eq 1 ]]; then
        PHYSNET_NAME="physnet"
      else
        PHYSNET_NAME="physnet${i}"
      fi
      oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${ns}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "${PHYSNET_NAME}",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${ns}/${NAD_NAME}"
  }'
EOF
      echo "Created NAD ${NAD_NAME} (${PHYSNET_NAME}:br-ex, subnets-less passthrough → ostestbm DHCP)"
    done

    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=false"
    for i in $(seq 1 "${NETWORK_COUNT}"); do
      EXTRA_ARGS="${EXTRA_ARGS} --additional-network name:${ns}/localnet-${i}"
    done
  elif [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-vlan" ]]; then
    # Localnet with VLAN: VMs connect to a tagged VLAN via a dedicated OVS bridge.
    #   - NNCP creates br-localnet + VLAN sub-interface and OVN bridge-mapping
    #   - dnsmasq on br-ex.<vlan-id> (per node) serves DHCP/DNS before workers boot
    #   - NAD is subnets-less L2 passthrough (no OVN IPAM)
    #   - attach-default-network=false — workers use only the localnet VLAN NIC

    ns="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
    LOCALNET_VLAN_ID="${LOCALNET_VLAN_ID:-100}"
    LOCALNET_VLAN_BRIDGE="${LOCALNET_VLAN_BRIDGE:-br-localnet}"
    LOCALNET_VLAN_PHYSNET="${LOCALNET_VLAN_PHYSNET:-localnet-physnet}"
    LOCALNET_VLAN_BOND="${LOCALNET_VLAN_BOND:-br-ex}"
    LOCALNET_VLAN_GATEWAY="${LOCALNET_VLAN_GATEWAY:-192.168.112.1}"
    LOCALNET_VLAN_DHCP_RANGE_START="${LOCALNET_VLAN_DHCP_RANGE_START:-192.168.112.100}"
    LOCALNET_VLAN_DHCP_RANGE_END="${LOCALNET_VLAN_DHCP_RANGE_END:-192.168.112.240}"
    LOCALNET_VLAN_INGRESS_VIP="${LOCALNET_VLAN_INGRESS_VIP:-192.168.111.4}"
    LOCALNET_VLAN_DHCP_INTERFACE="${LOCALNET_VLAN_DHCP_INTERFACE:-${LOCALNET_VLAN_BOND}.${LOCALNET_VLAN_ID}}"
    LOCALNET_VLAN_ATTACH_DEFAULT="false"

    echo "Setting up localnet-vlan: VLAN ${LOCALNET_VLAN_ID}, bridge ${LOCALNET_VLAN_BRIDGE}, physnet ${LOCALNET_VLAN_PHYSNET}..."

    # Verify NMState operator is installed (required for NNCP).
    # Install via operatorhub-subscribe-nmstate-operator step in the workflow pre chain.
    if ! oc get crd nodenetworkconfigurationpolicies.nmstate.io &>/dev/null; then
      echo "ERROR: NMState operator not installed. NNCP CRD not found."
      echo "Add operatorhub-subscribe-nmstate-operator step to the workflow pre chain."
      exit 1
    fi
    echo "NMState operator verified (NNCP CRD present)"

    if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
      discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
      if ! discover_ovn_container_names "${discovery_pod}"; then
        echo "ERROR: Failed to discover OVN container names" >&2
        exit 1
      fi
    fi

    # Apply NNCP to create the OVS bridge and map it to the VLAN sub-interface on
    # each worker node. NMState creates: bond-interface.VLAN -> br-localnet, then
    # OVN bridge-mapping: localnet-physnet:br-localnet.
    echo "Applying NodeNetworkConfigurationPolicy for VLAN ${LOCALNET_VLAN_ID}..."
    oc apply -f - <<NNCP_EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: localnet-vlan-${LOCALNET_VLAN_ID}
spec:
  nodeSelector:
    kubernetes.io/os: linux
  desiredState:
    ovn:
      bridge-mappings:
        - localnet: ${LOCALNET_VLAN_PHYSNET}
          bridge: ${LOCALNET_VLAN_BRIDGE}
          state: present
    interfaces:
      - name: ${LOCALNET_VLAN_BRIDGE}
        type: ovs-bridge
        state: up
        bridge:
          options:
            stp: false
          port:
            - name: ${LOCALNET_VLAN_BOND}.${LOCALNET_VLAN_ID}
              vlan:
                mode: access
                tag: ${LOCALNET_VLAN_ID}
NNCP_EOF

    echo "Waiting for NNCP localnet-vlan-${LOCALNET_VLAN_ID} to be Available..."
    if ! oc wait nncp "localnet-vlan-${LOCALNET_VLAN_ID}" \
      --for=condition=Available --timeout=300s 2>/dev/null; then
      echo "WARNING: NNCP not Available after 300s, checking status..."
      oc get nncp "localnet-vlan-${LOCALNET_VLAN_ID}" -o yaml 2>/dev/null || true
    fi

    localnet_vlan_configure_br_localnet_dhcp "${CLUSTER_NAME}" "${LOCALNET_VLAN_ID}" \
      "${LOCALNET_VLAN_DHCP_INTERFACE}" "${LOCALNET_VLAN_GATEWAY}" \
      "${LOCALNET_VLAN_DHCP_RANGE_START}" "${LOCALNET_VLAN_DHCP_RANGE_END}" \
      "${LOCALNET_VLAN_INGRESS_VIP}" "${LOCALNET_VLAN_BOND}" || {
      echo "ERROR: ${LOCALNET_VLAN_DHCP_INTERFACE} dnsmasq configuration failed" >&2
      exit 1
    }

    # Verify bridge-mappings include the new physnet on all nodes
    echo "Verifying bridge-mappings on all nodes..."
    for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
      OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
        --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')
      [[ -z "${OVN_POD}" ]] && continue
      MAPPINGS=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
        ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null || true)
      echo "  ${NODE}: ${MAPPINGS}"
    done

    # Create subnets-less localnet NAD (L2 passthrough to the VLAN; DHCP on br-localnet).
    oc apply -f - <<NAD_EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-vlan
  namespace: ${ns}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "${LOCALNET_VLAN_PHYSNET}",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${ns}/localnet-vlan",
      "vlanID": ${LOCALNET_VLAN_ID}
  }'
NAD_EOF
    echo "Created NAD localnet-vlan (${LOCALNET_VLAN_PHYSNET}:${LOCALNET_VLAN_BRIDGE}, VLAN ${LOCALNET_VLAN_ID}, subnets-less passthrough)"

    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=${LOCALNET_VLAN_ATTACH_DEFAULT} --additional-network name:${ns}/localnet-vlan"
  else
    # Existing macvlan path
    oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-bridge-whereabouts
  namespace: ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "whereabouts",
      "type": "macvlan",
      "master": "enp3s0",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.221.0/24"
      }
  }'
EOF
    if [[ "${ATTACH_DEFAULT_NETWORK}" == "true" ]]; then
      EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=true --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
    else
      EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=false --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
    fi
  fi
fi

if [[ -f "${SHARED_DIR}/GPU_DEVICE_NAME" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --host-device-name $(cat "${SHARED_DIR}/GPU_DEVICE_NAME"),count:2"
fi

EXTRA_ARGS="${EXTRA_ARGS} --network-type=${HYPERSHIFT_NETWORK_TYPE} "

if [[ $HYPERSHIFT_NP_AUTOREPAIR == "true" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --auto-repair"
fi

case "${IP_STACK}" in
 "v4")
   EXTRA_ARGS="${EXTRA_ARGS} --service-cidr 172.32.0.0/16 --cluster-cidr 10.136.0.0/14 "
   ;;
 "v4v6")
   # Use explicit CIDRs with IPv4 first (primary) since --default-dual doesn't work for KubeVirt
   # Use non-conflicting IPv6 CIDRs (fd03::/48, fd04::/112) to avoid conflicts with management cluster
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr 10.132.0.0/14 --cluster-cidr fd03::/48 --service-cidr 172.31.0.0/16 --service-cidr fd04::/112 "
   ;;
 "v6v4")
   # Use explicit CIDRs with IPv6 first (primary) for v6v4 stack
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr fd03::/48 --cluster-cidr 10.132.0.0/14 --service-cidr fd04::/112 --service-cidr 172.31.0.0/16 "
   ;;
 "v6")
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr fd03::/48 --service-cidr fd04::/112 "
   ;;
esac

echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
# Workaround for: https://issues.redhat.com/browse/OCPBUGS-42867
if [[ $HYPERSHIFT_CREATE_CLUSTER_RENDER == "true" ]]; then

  RENDER_COMMAND="--render --render-sensitive"
  OCP_MINOR_VERSION=$(oc version | grep "Server Version" | cut -d '.' -f2)
  if [ "$OCP_MINOR_VERSION" -le "16" ]; then
      RENDER_COMMAND="--render"
  fi

  # shellcheck disable=SC2086
  "${HCP_CLI}" create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
    --name "${CLUSTER_NAME}" \
    --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
    --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
    --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
    --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
    --root-volume-size 64 \
    --release-image "${RELEASE_IMAGE}" \
    --pull-secret "${PULL_SECRET_PATH}" \
    --generate-ssh \
    --control-plane-availability-policy "${CONTROL_PLANE_AVAILABILITY}" \
    --infra-availability-policy "${INFRA_AVAILABILITY}" \
    ${RENDER_COMMAND} > "${SHARED_DIR}/hypershift_create_cluster_render.yaml"

  oc apply -f "${SHARED_DIR}/hypershift_create_cluster_render.yaml"
else
  # shellcheck disable=SC2086
  eval "${HCP_CLI} create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
    --name ${CLUSTER_NAME} \
    --namespace ${CLUSTER_NAMESPACE_PREFIX} \
    --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
    --memory ${HYPERSHIFT_NODE_MEMORY}Gi \
    --cores ${HYPERSHIFT_NODE_CPU_CORES} \
    --root-volume-size 64 \
    --release-image ${RELEASE_IMAGE} \
    --pull-secret ${PULL_SECRET_PATH} \
    --generate-ssh \
    --control-plane-availability-policy ${CONTROL_PLANE_AVAILABILITY} \
    --infra-availability-policy ${INFRA_AVAILABILITY} $(support_np_skew)"
fi

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${CLUSTER_NAMESPACE_PREFIX} "hostedcluster/${CLUSTER_NAME}"
echo "Cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --namespace="${CLUSTER_NAMESPACE_PREFIX}" --name="${CLUSTER_NAME}" >"${SHARED_DIR}/nested_kubeconfig"

if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
  MULTI_NAMESPACE="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
  ensure_localnet_multi_worker_kubelet_started "${MULTI_NAMESPACE}" || {
    echo "ERROR: localnet-multi worker kubelet bootstrap failed" >&2
    exit 1
  }
  echo "Waiting for NodePool to become Ready"
  oc wait --timeout="${LOCALNET_MULTI_NODEPOOL_READY_TIMEOUT:-45m}" \
    --for=condition=Ready --namespace="${CLUSTER_NAMESPACE_PREFIX}" "nodepool/${CLUSTER_NAME}"
  configure_localnet_multi_egress_prereqs
fi

# Localnet-VLAN post-creation: clear port security for EgressIP (DHCP is on br-localnet pre-boot).
if [[ "${ATTACH_DEFAULT_NETWORK:-}" == "localnet-vlan" ]]; then
  LOCALNET_VLAN_NS="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"

  echo "Waiting for ${HYPERSHIFT_NODE_COUNT} worker VMIs to be running..."
  for _ in $(seq 1 60); do
    running_count=$(oc get vmi -n "${LOCALNET_VLAN_NS}" --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "${running_count}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${running_count} worker VMIs are running"
      break
    fi
    echo "Waiting for VMIs... (${running_count}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  clear_ovn_localnet_lsp_port_security "${LOCALNET_VLAN_NS}" || {
    echo "ERROR: failed to clear port security on localnet-vlan LSPs" >&2
    exit 1
  }

  echo "Waiting for NodePool to become Ready"
  oc wait --timeout="${LOCALNET_VLAN_NODEPOOL_READY_TIMEOUT:-45m}" \
    --for=condition=Ready --namespace="${CLUSTER_NAMESPACE_PREFIX}" "nodepool/${CLUSTER_NAME}"

  echo "Localnet-VLAN post-creation setup complete"
fi

if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet" ]]; then
  LOCALNET_NAMESPACE="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
  LOCALNET_SUBNET="192.168.223.0/24"
  LOCALNET_GATEWAY="192.168.223.1"

  echo "Waiting for VMIs to be running..."
  for _ in $(seq 1 60); do
    RUNNING_COUNT=$(oc get vmi -n "${LOCALNET_NAMESPACE}" --no-headers 2>/dev/null \
      | grep -c Running || true)
    if [[ "${RUNNING_COUNT}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${RUNNING_COUNT} VMIs are running"
      break
    fi
    echo "Waiting for VMIs... (${RUNNING_COUNT}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  configure_ovn_localnet_lsp_dhcp "${LOCALNET_NAMESPACE}" "${LOCALNET_SUBNET}" "${LOCALNET_GATEWAY}" || {
    echo "ERROR: OVN DHCP configuration failed for localnet" >&2
    exit 1
  }
  echo "OVN DHCP and port security configuration complete for localnet interfaces"

  # Enable IP forwarding on enp2s0 (the secondary/localnet NIC) inside each
  # hosted cluster VM. OVN multi-NIC EgressIP uses iptables SNAT to change the
  # source IP on enp2s0, but the de-SNATed return traffic needs to be forwarded
  # from enp2s0 back to ovn-k8s-mp0. Without forwarding enabled on enp2s0,
  # these return packets are silently dropped by the kernel.
  # OVN-Kubernetes only enables forwarding on interfaces it manages (br-ex,
  # ovn-k8s-mp0) but not on the secondary NIC.
  NESTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  if [[ -f "${NESTED_KUBECONFIG}" ]]; then
    echo "Waiting for OVN node pods to be ready in hosted cluster..."
    for _ in $(seq 1 60); do
      OVN_READY_COUNT=$(KUBECONFIG="${NESTED_KUBECONFIG}" oc get pods -n openshift-ovn-kubernetes \
        -l app=ovnkube-node --no-headers 2>/dev/null | grep -c Running || true)
      if [[ "${OVN_READY_COUNT}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
        echo "All ${OVN_READY_COUNT} OVN node pods are running"
        break
      fi
      echo "Waiting for OVN node pods... (${OVN_READY_COUNT}/${HYPERSHIFT_NODE_COUNT} running)"
      sleep 10
    done

    echo "Enabling IP forwarding on enp2s0 for all hosted cluster nodes..."
    for OVN_NODE_POD in $(KUBECONFIG="${NESTED_KUBECONFIG}" oc get pods -n openshift-ovn-kubernetes \
      -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      KUBECONFIG="${NESTED_KUBECONFIG}" oc exec -n openshift-ovn-kubernetes "${OVN_NODE_POD}" \
        -c "${OVN_OVS_CONTAINER}" -- sysctl -w net.ipv4.conf.enp2s0.forwarding=1 2>/dev/null || true
      echo "Enabled enp2s0 forwarding on ${OVN_NODE_POD}"
    done
    echo "IP forwarding configuration complete for hosted cluster nodes"
  else
    echo "WARNING: Nested kubeconfig not found at ${NESTED_KUBECONFIG}, skipping enp2s0 forwarding setup"
  fi

  # Deploy ip-echo on the management cluster with localnet NAD for EgressIP
  # source-IP verification. The ip-echo pod gets a localnet IP that is NOT in the
  # hosted cluster's OVN node address set, so EgressIP reroute + SNAT applies
  # to traffic going to it. Without this, traffic to hosted cluster node IPs
  # (including localnet IPs) is exempted from EgressIP by OVN priority 102 policy.
  #
  # The ip-echo pod is deployed in a dedicated namespace (not the HyperShift
  # control plane namespace) to prevent HyperShift's control plane operator from
  # garbage-collecting it during namespace reconciliation.
  IPECHO_NAMESPACE="egressip-ipecho-${CLUSTER_NAME}"
  echo "Deploying ip-echo in dedicated namespace ${IPECHO_NAMESPACE}..."
  oc create namespace "${IPECHO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label ns "${IPECHO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true

  # Create a localnet NAD in the ip-echo namespace (same config as the hosted cluster namespace)
  oc apply -f - <<IPECHO_NAD_EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-network
  namespace: ${IPECHO_NAMESPACE}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${IPECHO_NAMESPACE}/localnet-network",
      "subnets": "192.168.223.0/24"
  }'
IPECHO_NAD_EOF

  IPECHO_TRIED_NODES=""
  for attempt in 1 2 3; do
    IPECHO_NODE=$(select_ipecho_node "${IPECHO_TRIED_NODES}") || exit 1
    IPECHO_TRIED_NODES="${IPECHO_TRIED_NODES} ${IPECHO_NODE}"
    echo "Scheduling ip-echo on node ${IPECHO_NODE} (attempt ${attempt})"
    oc delete pod egressip-ipecho -n "${IPECHO_NAMESPACE}" --ignore-not-found --force --grace-period=0 2>/dev/null || true

  oc apply -f - <<IPECHO_EOF
apiVersion: v1
kind: Pod
metadata:
  name: egressip-ipecho
  namespace: ${IPECHO_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: localnet-network
spec:
  nodeName: ${IPECHO_NODE}
  containers:
  - name: ip-echo
    image: quay.io/openshifttest/ip-echo:1.2.0
    ports:
    - containerPort: 80
      protocol: TCP
    securityContext:
      runAsUser: 0
  restartPolicy: Always
  tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
IPECHO_EOF

    if wait_for_ipecho_pod "${IPECHO_NAMESPACE}" 120; then
      break
    fi
    reason=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" -o jsonpath='{.status.reason}' 2>/dev/null || true)
    if [[ "${reason}" != "Evicted" ]]; then
      exit 1
    fi
    echo "ip-echo evicted from ${IPECHO_NODE}, will retry on another node" >&2
  done
  if ! oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: ip-echo pod failed to become Ready after retries" >&2
    exit 1
  fi

  IPECHO_LOCALNET_IP=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
    python3 -c "import sys,json; nets=json.loads(sys.stdin.read()); [print(n['ips'][0]) for n in nets if 'localnet' in n.get('name','')]")
  echo "ip-echo localnet IP: ${IPECHO_LOCALNET_IP}:80"
  echo "${IPECHO_LOCALNET_IP}:80" > "${SHARED_DIR}/kubevirt_ipecho_url"
elif [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
  # Deploy ip-echo on a passthrough localnet (default localnet-2) for EgressIP source-IP
  # verification. Passthrough NADs have no OVN IPAM; use a static Multus IP on net1 instead
  # of DHCP (avoids dhclient/NET_ADMIN in an init container on the mgmt cluster).
  IPECHO_NET_INDEX="${LOCALNET_MULTI_IPECHO_LOCALNET_INDEX:-2}"
  NETWORK_COUNT="${LOCALNET_MULTI_NETWORK_COUNT:-2}"
  IPECHO_STATIC_IP="${LOCALNET_MULTI_IPECHO_STATIC_IP:-192.168.111.250/24}"
  if [[ ${IPECHO_NET_INDEX} -lt 1 || ${IPECHO_NET_INDEX} -gt ${NETWORK_COUNT} ]]; then
    echo "ERROR: LOCALNET_MULTI_IPECHO_LOCALNET_INDEX=${IPECHO_NET_INDEX} must be between 1 and ${NETWORK_COUNT}" >&2
    exit 1
  fi
  IPECHO_NAD="localnet-${IPECHO_NET_INDEX}"
  if [[ ${IPECHO_NET_INDEX} -eq 1 ]]; then
    IPECHO_PHYSNET="physnet"
  else
    IPECHO_PHYSNET="physnet${IPECHO_NET_INDEX}"
  fi
  IPECHO_NAMESPACE="egressip-ipecho-${CLUSTER_NAME}"
  echo "Deploying ip-echo in dedicated namespace ${IPECHO_NAMESPACE} on ${IPECHO_NAD} (static ${IPECHO_STATIC_IP})..."
  oc create namespace "${IPECHO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label ns "${IPECHO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true

  oc apply -f - <<IPECHO_NAD_EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ${IPECHO_NAD}
  namespace: ${IPECHO_NAMESPACE}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "${IPECHO_PHYSNET}",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${IPECHO_NAMESPACE}/${IPECHO_NAD}"
  }'
IPECHO_NAD_EOF

  IPECHO_TRIED_NODES=""
  for attempt in 1 2 3; do
    IPECHO_NODE=$(select_ipecho_node "${IPECHO_TRIED_NODES}") || exit 1
    IPECHO_TRIED_NODES="${IPECHO_TRIED_NODES} ${IPECHO_NODE}"
    echo "Scheduling ip-echo on node ${IPECHO_NODE} (attempt ${attempt})"
    oc delete pod egressip-ipecho -n "${IPECHO_NAMESPACE}" --ignore-not-found --force --grace-period=0 2>/dev/null || true

  oc apply -f - <<IPECHO_EOF
apiVersion: v1
kind: Pod
metadata:
  name: egressip-ipecho
  namespace: ${IPECHO_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: |-
      [{
        "name": "${IPECHO_NAD}",
        "interface": "net1",
        "ips": ["${IPECHO_STATIC_IP}"]
      }]
spec:
  nodeName: ${IPECHO_NODE}
  containers:
  - name: ip-echo
    image: quay.io/openshifttest/ip-echo:1.2.0
    ports:
    - containerPort: 80
      protocol: TCP
    securityContext:
      runAsUser: 0
  restartPolicy: Always
  tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
IPECHO_EOF

    if wait_for_ipecho_pod "${IPECHO_NAMESPACE}" 120; then
      break
    fi
    reason=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" -o jsonpath='{.status.reason}' 2>/dev/null || true)
    if [[ "${reason}" != "Evicted" ]]; then
      exit 1
    fi
    echo "ip-echo evicted from ${IPECHO_NODE}, will retry on another node" >&2
  done
  if ! oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: ip-echo pod failed to become Ready after retries" >&2
    exit 1
  fi

  IPECHO_LOCALNET_IP="${IPECHO_STATIC_IP%%/*}"
  observed_ip=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
    python3 -c "import sys,json; nets=json.loads(sys.stdin.read() or '[]'); ips=[n['ips'][0] for n in nets if 'localnet' in n.get('name','') and n.get('ips')]; print(ips[0] if ips else '')" 2>/dev/null || true)
  if [[ -n "${observed_ip}" && "${observed_ip}" != "${IPECHO_LOCALNET_IP}" ]]; then
    echo "WARNING: ip-echo network-status IP ${observed_ip} differs from configured ${IPECHO_LOCALNET_IP}" >&2
    IPECHO_LOCALNET_IP="${observed_ip}"
  fi
  if [[ -z "${IPECHO_LOCALNET_IP}" ]]; then
    echo "ERROR: could not determine ip-echo localnet IP on ${IPECHO_NAD}" >&2
    exit 1
  fi
  echo "ip-echo localnet IP: ${IPECHO_LOCALNET_IP}:80"
  echo "${IPECHO_LOCALNET_IP}:80" > "${SHARED_DIR}/kubevirt_ipecho_url"
fi

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"