#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e ovn bgp no-overlay command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

OUTBOUND_SNAT="${NO_OVERLAY_OUTBOUND_SNAT:-Enabled}"
ROUTING_MODE="${NO_OVERLAY_ROUTING:-Unmanaged}"
BGP_TOPOLOGY="${NO_OVERLAY_BGP_TOPOLOGY:-}"

# bgpManagedConfig is required by the Network API when the default network asks for managed
# routing, and allowed, but not required, otherwise. Setting it on an unmanaged cluster is
# what lets individual CUDNs ask for managed routing there.
if [ "${ROUTING_MODE}" = "Managed" ] && [ -z "${BGP_TOPOLOGY}" ]; then
    BGP_TOPOLOGY="FullMesh"
fi

echo "NoOverlay configuration: outboundSNAT=${OUTBOUND_SNAT}, routing=${ROUTING_MODE}, bgpTopology=${BGP_TOPOLOGY:-<unset>}"

CLUSTER_NETWORK_V4="10.128.0.0/14"
CLUSTER_NETWORK_V6="fd01::/48"
# The packet server itself on the ostestbm cluster network.
ROUTE_REFLECTOR_V4="192.168.111.1"
ROUTE_REFLECTOR_V6="fd2e:6f44:5dd8:c956::1"

if [ "${ROUTING_MODE}" = "Managed" ]; then
    echo "Managed routing: OVN-Kubernetes peers the nodes with each other, skipping the external route reflector"
else
    echo "Setting up the FRR route reflector container on the packet server..."

ssh "${SSHOPTS[@]}" "root@${IP}" bash -x << 'EOFSETUP'
set -o nounset
set -o errexit
set -o pipefail

# Install podman if not already present: this step runs before
# baremetalds-devscripts-setup, which is what normally installs it.
if ! command -v podman &>/dev/null; then
    dnf install -y podman
fi

SUDO=
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
fi

CLI="$SUDO podman"
if ! command -v podman; then
    CLI="$SUDO docker"
    if ! command -v docker; then
        echo "ERROR: Neither podman nor docker found on this host"
        exit 1
    fi
fi
echo "Container CLI is: $CLI"

mkdir -p ~/frr-no-overlay

# The route reflector listens for the nodes rather than naming them: the cluster does not
# exist yet, so their addresses are not known at this point.
cat > ~/frr-no-overlay/frr.conf <<'EOFFRR'
frr defaults traditional
hostname rr-container
log stdout informational

router bgp 64512
 bgp router-id 192.168.111.1
 bgp cluster-id 192.168.111.1
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 bgp graceful-restart preserve-fw-state
 neighbor NODES peer-group
 neighbor NODES remote-as 64512
 bgp listen range 192.168.111.0/24 peer-group NODES
 bgp listen range fd2e:6f44:5dd8:c956::/64 peer-group NODES
 address-family ipv4 unicast
  neighbor NODES activate
  neighbor NODES route-reflector-client
 exit-address-family
 address-family ipv6 unicast
  neighbor NODES activate
  neighbor NODES route-reflector-client
 exit-address-family
exit

line vty
EOFFRR

cat > ~/frr-no-overlay/daemons <<'EOFDAEMONS'
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
pim6d=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no

vtysh_enable=yes
zebra_options=" -A 127.0.0.1 -s 90000000"
bgpd_options=" -A 127.0.0.1"

# Maximum number of FDs
MAX_FDS=1024
EOFDAEMONS

echo "Opening firewall port 179 for BGP..."
sudo firewall-cmd --zone=libvirt --add-port=179/tcp --permanent || true
sudo firewall-cmd --zone=libvirt --add-port=179/tcp || true

echo "Starting the FRR route reflector container..."
$CLI rm -f frr || true
$CLI run -d --name frr \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_ADMIN \
  -v ~/frr-no-overlay/frr.conf:/etc/frr/frr.conf:ro,Z \
  -v ~/frr-no-overlay/daemons:/etc/frr/daemons:ro,Z \
  quay.io/frrouting/frr:10.2.1 \
  /usr/lib/frr/docker-start

sleep 5
$CLI ps | grep frr
echo "FRR route reflector container is running"
EOFSETUP

    # Peering of the nodes with the route reflector above. OVN-Kubernetes merges the pod
    # subnets of the other nodes into the prefixes accepted here, so the filter only has to
    # name the cluster network.
    #
    # Both of these are replaced later by baremetalds-e2e-ovn-bgp-pre, which points the same
    # FRRConfiguration and RouteAdvertisements at the external FRR container it deploys on
    # the cluster network. They exist so that the cluster has pod to pod connectivity while
    # it installs, which on a no-overlay cluster depends on BGP being up.
    cat > "${SHARED_DIR}/manifest_frr-configuration-no-overlay.yaml" <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: receive-filtered
  namespace: openshift-frr-k8s
  labels:
    network: default
spec:
  bgp:
    routers:
    - asn: 64512
      neighbors:
      - address: ${ROUTE_REFLECTOR_V4}
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - ge: 23
              prefix: ${CLUSTER_NETWORK_V4}
      - address: ${ROUTE_REFLECTOR_V6}
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - ge: 64
              prefix: ${CLUSTER_NETWORK_V6}
EOF
    cat > "${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  advertisements:
  - PodNetwork
  frrConfigurationSelector:
    matchLabels:
      network: default
  networkSelectors:
  - networkSelectionType: DefaultNetwork
  # A network cannot be half overlay and half no-overlay, so every node is selected.
  nodeSelector: {}
EOF

    echo "FRR configuration manifest created at ${SHARED_DIR}/manifest_frr-configuration-no-overlay.yaml"
    cat "${SHARED_DIR}/manifest_frr-configuration-no-overlay.yaml"
    echo "Route advertisements manifest created at ${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml"
    cat "${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml"
fi

echo "Creating the network operator manifest with the NoOverlay transport..."

# Picked up by dev-scripts and handed to the installer. The transport is immutable once the
# cluster is installed, so it cannot be patched in afterwards like the rest of the BGP setup.
cat > "${SHARED_DIR}/manifest_network-operator-no-overlay.yaml" <<EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  additionalRoutingCapabilities:
    providers:
    - FRR
  defaultNetwork:
    type: OVNKubernetes
    ovnKubernetesConfig:
      routeAdvertisements: Enabled
      transport: NoOverlay
      noOverlayConfig:
        outboundSNAT: ${OUTBOUND_SNAT}
        routing: ${ROUTING_MODE}
EOF

if [ -n "${BGP_TOPOLOGY}" ]; then
    cat >> "${SHARED_DIR}/manifest_network-operator-no-overlay.yaml" <<EOF
      bgpManagedConfig:
        asNumber: 64512
        bgpTopology: ${BGP_TOPOLOGY}
EOF
fi

echo "Network operator manifest created at ${SHARED_DIR}/manifest_network-operator-no-overlay.yaml"
cat "${SHARED_DIR}/manifest_network-operator-no-overlay.yaml"
