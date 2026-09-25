#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Proves, before any test runs, that the address the EgressIP tests will curl is actually
# reachable from the guest nodes over each egress interface.
#
# This is the one gate every topology shares. Whether the egress path is the untagged
# secondary NIC, an 802.1Q subinterface on top of it, or a second independent NIC, and
# whether the echo target is inside that subnet or beyond a next hop, the requirement is
# identical: a lookup for the target constrained to that interface has to resolve, because
# ovnkube-node builds a secondary-host-network EgressIP's routing table by copying routes
# out of the link from main, filtered on output interface. If nothing is there to copy it
# synthesises a next-hopless "default dev <iface>" and the tests still "run" - they just
# time out on every curl and report the misleading "sourceIP was still included in [...]",
# which says nothing about the real cause.
#
# Both checks are deliberately per interface rather than global. An unqualified
# "ip route get" consults main as a whole and answers for whichever route has the lowest
# metric, so with two secondary NICs pointed at one target it would report success for
# both while only one of them actually has a route of its own. "oif" and curl's
# "--interface" each constrain the lookup the way the EgressIP routing table does.
#
# Runs after hypershift-agent-ovn-ipecho-provision, so it needs to be in the job's test
# sequence rather than in the workflow's pre.
#

if [[ ! -f "${SHARED_DIR}/ipecho_url" ]]; then
  echo "No ${SHARED_DIR}/ipecho_url; hypershift-agent-ovn-ipecho-provision did not run. Nothing to verify."
  exit 0
fi
if [[ ! -f "${SHARED_DIR}/egressip_secondary_iface" ]]; then
  echo "No ${SHARED_DIR}/egressip_secondary_iface; the cluster is not configured for"
  echo "EgressIP on a secondary interface. Nothing to verify."
  exit 0
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

guest() { oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" "$@"; }

IPECHO_URL="$(cat "${SHARED_DIR}/ipecho_url")"

# http://<host>:<port> -> <host>
IPECHO_TARGET="${IPECHO_URL#*://}"
IPECHO_TARGET="${IPECHO_TARGET%%:*}"

# Every egress path the job configured. The unsuffixed outputs are the first one - the
# VLAN subinterface when the job is tagged, the untagged NIC otherwise - and _2 is a
# second independent NIC when there is one.
SUFFIXES=("")
if [[ -f "${SHARED_DIR}/egressip_secondary_iface_2" ]]; then
  SUFFIXES+=("_2")
fi

echo "************ Verifying ${IPECHO_URL} is reachable over every egress interface ************"
echo "Echo target: ${IPECHO_TARGET}"
for suffix in "${SUFFIXES[@]}"; do
  echo "  egress path: $(cat "${SHARED_DIR}/egressip_secondary_iface${suffix}") on $(cat "${SHARED_DIR}/egressip_secondary_subnet${suffix}")"
done

NODES="$(guest get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${NODES}" ]]; then
  echo "ERROR: no nodes found in the guest cluster"
  exit 1
fi

failed=""
for suffix in "${SUFFIXES[@]}"; do
  iface="$(cat "${SHARED_DIR}/egressip_secondary_iface${suffix}")"
  subnet="$(cat "${SHARED_DIR}/egressip_secondary_subnet${suffix}")"
  node_ips="${SHARED_DIR}/egressip_secondary_node_ips${suffix}"

  echo "=== ${iface} (${subnet})"
  for node in ${NODES}; do
    echo "--- ${node}"

    # The route lookup and the request are the same question asked two ways: whether the
    # kernel can reach the target out of this specific interface, and what the far end
    # actually sees as the source. They can disagree - a route whose reply never arrives
    # looks fine to "ip route get" and fails the curl.
    route="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host ip -4 route get "${IPECHO_TARGET}" oif "${iface}" 2>/dev/null | tr -d '\r' | head -1)" || true
    echo "  route: ${route:-<none>}"
    if ! echo "${route}" | grep -q "dev ${iface}"; then
      echo "  ERROR: ${IPECHO_TARGET} does not resolve out of ${iface} in the main table."
      echo "         An EgressIP on this interface will blackhole: ovnkube-node copies routes"
      echo "         out of the link from main, and there is nothing here to copy."
      echo "         Routes currently on ${iface}:"
      guest debug -n default "node/${node}" --quiet -- \
        chroot /host ip -4 route show dev "${iface}" || true
      failed="yes"
      continue
    fi

    # --interface binds the request to this link, so the lookup is constrained exactly as
    # the EgressIP routing table constrains it. The echoed source is expected to be this
    # node's address on this egress subnet.
    seen="$(guest debug -n default "node/${node}" --quiet -- \
      chroot /host curl -s -m 15 --interface "${iface}" "${IPECHO_URL}" 2>/dev/null | tr -d '[:space:]')" || true
    expected="$(grep "^${node} " "${node_ips}" 2>/dev/null | awk '{print $2}' | cut -d/ -f1)"
    echo "  echoed source: ${seen:-<no response>} (expected ${expected:-unknown})"

    if [[ -z "${seen}" ]]; then
      echo "  ERROR: no response from ${IPECHO_URL} over ${iface}."
      echo "         The route is right, so the target is not answering on this path or the"
      echo "         reply is being dropped. Check that the echo service is up on the"
      echo "         dev-scripts host, that its address is present on a local link there, and"
      echo "         that the port is open in the firewalld zone of the bridge facing THIS"
      echo "         network - the zone is per interface, so a second extra network needs its"
      echo "         gateway listed in IPECHO_EXTRA_HOST_IPS."
      failed="yes"
      continue
    fi
    if [[ -n "${expected}" && "${seen}" != "${expected}" ]]; then
      echo "  ERROR: the echo saw ${seen}, not this node's ${iface} address ${expected}."
      echo "         The request left by a different path than the route lookup suggested."
      failed="yes"
      continue
    fi
    echo "  ok"
  done
done

if [[ -n "${failed}" ]]; then
  echo "************ Echo target is NOT usable for EgressIP testing ************"
  exit 1
fi

echo "************ ${IPECHO_URL} reachable from every node over every egress interface ************"
