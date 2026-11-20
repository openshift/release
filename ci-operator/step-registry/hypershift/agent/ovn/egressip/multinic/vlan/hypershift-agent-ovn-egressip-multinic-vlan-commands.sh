#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Puts the guest cluster's EgressIP egress path on an 802.1Q VLAN, configured day-2
# through kubernetes-nmstate rather than at install time. This reproduces the mechanism
# the customer asked about: a tagged subinterface with its own routing table and a route
# rule steering that interface's traffic into it.
#
# Runs after hypershift-agent-ovn-egressip-multinic, which has already discovered the
# untagged secondary NIC, enabled forwarding and stopped it installing a default route.
# This step layers the VLAN on top and repoints the SHARED_DIR outputs at it.
#
# No-op unless EGRESSIP_VLAN_ID is set, so the untagged jobs sharing this workflow are
# unaffected.
#

EGRESSIP_VLAN_ID="${EGRESSIP_VLAN_ID:-}"
if [[ -z "${EGRESSIP_VLAN_ID}" ]]; then
  echo "EGRESSIP_VLAN_ID is unset; leaving the guest cluster on the untagged secondary NIC"
  exit 0
fi

echo "************ Configuring an 802.1Q egress VLAN on the guest cluster ************"

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

if [[ ! -f "${SHARED_DIR}/egressip_secondary_iface" ]]; then
  echo "ERROR: ${SHARED_DIR}/egressip_secondary_iface is missing."
  echo "       hypershift-agent-ovn-egressip-multinic has to run before this step."
  exit 1
fi
BASE_IFACE="$(cat "${SHARED_DIR}/egressip_secondary_iface")"
BASE_SUBNET="$(cat "${SHARED_DIR}/egressip_secondary_subnet")"
BASE_PREFIX="${BASE_SUBNET%.*/*}."

# A job may provision a second, independent secondary NIC. The VLAN is layered only on
# the first; the second stays untagged and keeps the EgressIP configuration the previous
# step gave it. It matters here for two things only: the Tuned profile is a single object
# covering every egress interface, and the default-route assertion has to cover it too.
SECOND_IFACE=""
if [[ -f "${SHARED_DIR}/egressip_secondary_iface_2" ]]; then
  SECOND_IFACE="$(cat "${SHARED_DIR}/egressip_secondary_iface_2")"
fi

VLAN_PREFIX="${EGRESSIP_VLAN_SUBNET%.*/*}."
VLAN_MASK="${EGRESSIP_VLAN_SUBNET#*/}"
VLAN_GATEWAY="${EGRESSIP_VLAN_GATEWAY:-${VLAN_PREFIX}1}"

echo "Base interface: ${BASE_IFACE} on ${BASE_SUBNET}"
if [[ -n "${SECOND_IFACE}" ]]; then
  echo "Second untagged secondary interface (left alone): ${SECOND_IFACE}"
fi
echo "VLAN ${EGRESSIP_VLAN_ID}: ${EGRESSIP_VLAN_IFACE} on ${EGRESSIP_VLAN_SUBNET}, next hop ${VLAN_GATEWAY}"
echo "Dedicated table ${EGRESSIP_VLAN_TABLE_ID}, rule priority ${EGRESSIP_VLAN_RULE_PRIORITY}"
echo "Off-subnet echo route: ${EGRESSIP_REMOTE_SUBNET:-<none>}"

NODES="$(guest get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${NODES}" ]]; then
  echo "ERROR: no nodes found in the guest cluster"
  exit 1
fi
echo "Guest nodes: $(echo "${NODES}" | tr '\n' ' ')"

#
# 1. kubernetes-nmstate, on the GUEST cluster. The handler DaemonSet has to run on the
#    machines whose interfaces are being configured. NMStateConfig on the management
#    cluster (agent-install.openshift.io) is an unrelated day-1, MAC-matched API.
#
echo "Installing kubernetes-nmstate..."

# Take the catalog the operator is actually served by rather than assuming one is
# present. A hosted cluster gets its CatalogSources from the control plane, and which
# ones exist depends on how the payload was built.
AVAILABLE_SOURCES="$(guest get packagemanifests -n openshift-marketplace \
  -o jsonpath="{range .items[?(@.metadata.name=='kubernetes-nmstate-operator')]}{.status.catalogSource}{'\n'}{end}" || true)"
if [[ -z "${AVAILABLE_SOURCES}" ]]; then
  echo "ERROR: no catalog in the guest cluster serves kubernetes-nmstate-operator"
  guest get catalogsource -n openshift-marketplace || true
  exit 1
fi
if echo "${AVAILABLE_SOURCES}" | grep -qx "${NMSTATE_SUB_SOURCE}"; then
  SUB_SOURCE="${NMSTATE_SUB_SOURCE}"
else
  SUB_SOURCE="$(echo "${AVAILABLE_SOURCES}" | head -1)"
  echo "NMSTATE_SUB_SOURCE=${NMSTATE_SUB_SOURCE} does not serve the operator; using ${SUB_SOURCE}"
fi
echo "Subscribing from catalog ${SUB_SOURCE}, channel ${NMSTATE_SUB_CHANNEL}"

# Deliberately no ImageDigestMirrorSet. On a hosted cluster IDMS/ITMS/OperatorHub are
# control-plane owned and a ValidatingAdmissionPolicy denies guest-side writes; the
# mirrors are declared in HostedCluster.spec.imageContentSources and rendered into the
# IDMS named "cluster".
cat <<EOF | guest apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
  labels:
    kubernetes.io/metadata.name: openshift-nmstate
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
  - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: ${NMSTATE_SUB_CHANNEL}
  name: kubernetes-nmstate-operator
  source: ${SUB_SOURCE}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "Waiting for the nmstate CSV to reach Succeeded..."
csv_ok=""
for _ in $(seq 1 60); do
  phase="$(guest get csv -n openshift-nmstate \
    -o jsonpath='{range .items[?(@.spec.displayName=="Kubernetes NMState Operator")]}{.status.phase}{"\n"}{end}' 2>/dev/null | head -1)" || true
  if [[ "${phase}" == "Succeeded" ]]; then
    csv_ok="yes"
    break
  fi
  sleep 10
done
if [[ -z "${csv_ok}" ]]; then
  echo "ERROR: the kubernetes-nmstate CSV never reached Succeeded"
  guest get csv,subscription,installplan -n openshift-nmstate || true
  exit 1
fi

# The NMState CR creates the handler DaemonSet and the webhook. The CRD only exists once
# the CSV has installed, hence the ordering.
guest apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF

# The handler DaemonSet and the webhook are created by the operator in response to that
# CR, a few seconds later. "oc rollout status" on a resource that does not exist yet
# errors out immediately rather than waiting for it, so poll for creation first.
echo "Waiting for the nmstate operands to appear..."
operands_ok=""
for _ in $(seq 1 60); do
  if guest -n openshift-nmstate get ds nmstate-handler >/dev/null 2>&1 &&
     guest -n openshift-nmstate get deploy nmstate-webhook >/dev/null 2>&1; then
    operands_ok="yes"
    break
  fi
  sleep 5
done
if [[ -z "${operands_ok}" ]]; then
  echo "ERROR: the nmstate operator never created ds/nmstate-handler and deploy/nmstate-webhook"
  guest get -n openshift-nmstate nmstate,deploy,ds,pods || true
  exit 1
fi

guest -n openshift-nmstate rollout status ds/nmstate-handler --timeout=10m
# The webhook mutates NodeNetworkConfigurationPolicy on admission, so applying a policy
# before it has endpoints fails the call outright.
guest -n openshift-nmstate rollout status deploy/nmstate-webhook --timeout=5m

#
# 2. One NodeNetworkConfigurationPolicy per node. An NNCP applies the same desiredState
#    to everything its selector matches, and the addresses are static and differ, so they
#    cannot share one policy. Each node keeps the host part it already holds on the
#    untagged network, which keeps the numbering readable against libvirt's reservations.
#
for node in ${NODES}; do
  base_addr="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' \
    | tr -d '[]"' | tr ',' '\n' | grep "^${BASE_PREFIX}" | head -1)" || true
  if [[ -z "${base_addr}" ]]; then
    echo "ERROR: ${node} advertises no address in ${BASE_SUBNET}; cannot derive its VLAN address"
    exit 1
  fi
  host_part="${base_addr%%/*}"
  host_part="${host_part##*.}"
  vlan_addr="${VLAN_PREFIX}${host_part}"
  echo "  ${node}: ${base_addr} -> ${vlan_addr}/${VLAN_MASK} on ${EGRESSIP_VLAN_IFACE}"

  # The route split below is the whole point of the exercise.
  #
  # Table ${EGRESSIP_VLAN_TABLE_ID} plus the rule reproduce the customer's mechanism, and
  # OVN-Kubernetes ignores both. For a secondary-host-network EgressIP it builds its own
  # table at <ifindex>+1000 and fills it by copying routes out of this link from the MAIN
  # table only, filtered on output interface (generateRoutesForLink in
  # pkg/node/controllers/egressip/egressip.go). A route in a user table is invisible to
  # it, and if nothing gatewayed gets copied it synthesises "default dev <iface>" with no
  # next hop, so the kernel ARPs for the destination itself and every off-subnet target
  # blackholes.
  #
  # That is why the route to the echo server's off-subnet address goes in main. It is a
  # specific prefix rather than a default, so it never competes with the default route via
  # br-ex.
  #
  # The metric is explicit because a second secondary NIC, when the job has one, holds a
  # route to this same prefix out of its own link. The kernel refuses two routes for one
  # prefix at the same metric, so they have to differ; both then sit in main and the
  # per-link filter hands each EgressIP table its own.
  remote_route=""
  if [[ -n "${EGRESSIP_REMOTE_SUBNET}" ]]; then
    remote_route="
      - destination: ${EGRESSIP_REMOTE_SUBNET}
        next-hop-interface: ${EGRESSIP_VLAN_IFACE}
        next-hop-address: ${VLAN_GATEWAY}
        metric: ${EGRESSIP_REMOTE_ROUTE_METRIC_BASE}"
  fi

  cat <<EOF | guest apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: egressip-vlan-${node}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  desiredState:
    interfaces:
    - name: ${EGRESSIP_VLAN_IFACE}
      type: vlan
      state: up
      vlan:
        base-iface: ${BASE_IFACE}
        id: ${EGRESSIP_VLAN_ID}
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: ${vlan_addr}
          prefix-length: ${VLAN_MASK}
      ipv6:
        enabled: false
    routes:
      config:${remote_route}
      - destination: ${EGRESSIP_VLAN_SUBNET}
        next-hop-interface: ${EGRESSIP_VLAN_IFACE}
        table-id: ${EGRESSIP_VLAN_TABLE_ID}
      - destination: 0.0.0.0/0
        next-hop-interface: ${EGRESSIP_VLAN_IFACE}
        next-hop-address: ${VLAN_GATEWAY}
        table-id: ${EGRESSIP_VLAN_TABLE_ID}
    route-rules:
      config:
      - ip-from: ${vlan_addr}/32
        route-table: ${EGRESSIP_VLAN_TABLE_ID}
        priority: ${EGRESSIP_VLAN_RULE_PRIORITY}
EOF
done

echo "Waiting for every NNCP to go Available..."
if ! guest wait nncp --all --for=condition=Available --timeout=15m; then
  echo "ERROR: at least one NodeNetworkConfigurationPolicy did not converge"
  guest get nncp,nnce -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.status=="True")].type,MSG:.status.conditions[?(@.status=="True")].message' || true
  exit 1
fi
guest get nncp

#
# 3. Extend the Tuned profile to the VLAN. Re-rendered rather than patched because
#    NodePool.spec.tuningConfig already points at this ConfigMap by name and a second
#    Tuned object matching the same nodes would simply lose the priority contest.
#    Keep in sync with hypershift-agent-ovn-egressip-multinic, which creates it - which
#    also means re-emitting the second NIC's sysctls when the job provisioned one, since
#    re-rendering replaces the whole object.
#
TUNED_IFACES=("${BASE_IFACE}" "${EGRESSIP_VLAN_IFACE}")
if [[ -n "${SECOND_IFACE}" ]]; then
  TUNED_IFACES+=("${SECOND_IFACE}")
fi
sysctl_lines=""
for iface in "${TUNED_IFACES[@]}"; do
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
echo "Re-rendered ${TUNED_CONFIGMAP_NAME} covering ${TUNED_IFACES[*]}"

echo "Waiting for the sysctl to land on every guest node..."
for node in ${NODES}; do
  ok=""
  for _ in $(seq 1 30); do
    value="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host sysctl -n "net.ipv4.conf.${EGRESSIP_VLAN_IFACE}.forwarding" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "${value}" == "1" ]]; then
      ok="yes"
      break
    fi
    sleep 10
  done
  if [[ -z "${ok}" ]]; then
    echo "ERROR: net.ipv4.conf.${EGRESSIP_VLAN_IFACE}.forwarding is not 1 on ${node}"
    guest get pods -n openshift-cluster-node-tuning-operator || true
    exit 1
  fi
  echo "  ${node}: forwarding=1"
done

#
# 4. nmstate owns an interface completely once it touches one, and ipv4.never-default was
#    set on the base NIC with nmcli, outside its knowledge. Confirm it did not reintroduce
#    a competing default route.
#
echo "Checking the default route is still single and via br-ex..."
EGRESS_PATH_IFACES=("${BASE_IFACE}" "${EGRESSIP_VLAN_IFACE}")
if [[ -n "${SECOND_IFACE}" ]]; then
  EGRESS_PATH_IFACES+=("${SECOND_IFACE}")
fi
for node in ${NODES}; do
  routes="$(guest debug -n default "node/${node}" --quiet -- \
    chroot /host ip -4 route show default 2>/dev/null)" || true
  echo "  ${node}: $(echo "${routes}" | tr '\n' '|')"
  for iface in "${EGRESS_PATH_IFACES[@]}"; do
    if echo "${routes}" | grep -q "dev ${iface}"; then
      echo "ERROR: ${node} has a default route via ${iface}; it would take over node traffic"
      exit 1
    fi
  done
done

#
# 5. The go/no-go. ovnkube-cluster-manager picks an egress node purely from this
#    annotation, so if the VLAN subnet never appears no EgressIP will be assigned. The
#    interesting part is that it is populated dynamically: the VLAN is created long after
#    ovnkube-node started, and no restart is needed.
#
echo "Checking k8s.ovn.org/host-cidrs advertises ${EGRESSIP_VLAN_SUBNET}..."
for node in ${NODES}; do
  ok=""
  for _ in $(seq 1 18); do
    cidrs="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' || true)"
    if [[ "${cidrs}" == *"${VLAN_PREFIX}"* ]]; then
      ok="yes"
      break
    fi
    sleep 10
  done
  if [[ -z "${ok}" ]]; then
    echo "ERROR: ${node} host-cidrs does not advertise ${EGRESSIP_VLAN_SUBNET}: ${cidrs:-<empty>}"
    exit 1
  fi
  echo "  ${node}: ${cidrs}"
done

#
# 6. Repoint the outputs at the VLAN. The untagged values written by the previous step
#    are overwritten, so the tests draw EgressIPs from the tagged subnet and assert
#    against the tagged interface. The _2 outputs, if the job provisioned a second NIC,
#    are deliberately left as they are: that interface is untagged in both topologies.
#
echo "${EGRESSIP_VLAN_IFACE}" > "${SHARED_DIR}/egressip_secondary_iface"
echo "${EGRESSIP_VLAN_SUBNET}" > "${SHARED_DIR}/egressip_secondary_subnet"
echo "${EGRESSIP_VLAN_ID}" > "${SHARED_DIR}/egressip_secondary_vlan_id"
: > "${SHARED_DIR}/egressip_secondary_node_ips"
for node in ${NODES}; do
  addr="$(guest get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}' \
    | tr -d '[]"' | tr ',' '\n' | grep "^${VLAN_PREFIX}" | head -1)" || true
  echo "${node} ${addr}" >> "${SHARED_DIR}/egressip_secondary_node_ips"
done

echo "************ Guest cluster ready for EgressIP on ${EGRESSIP_VLAN_IFACE} ************"
cat "${SHARED_DIR}/egressip_secondary_node_ips"
