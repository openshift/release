#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "Setting up FRR route reflector container on remote server..."

ssh "${SSHOPTS[@]}" "root@${IP}" bash -x << 'EOFSETUP'
set -o nounset
set -o errexit
set -o pipefail

# Create configuration directory and FRR config
mkdir -p ~/frr-no-overlay

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
 address-family ipv4 unicast
  neighbor NODES activate
  neighbor NODES route-reflector-client
 exit-address-family
exit

line vty
EOFFRR

echo "FRR configuration created at ~/frr-no-overlay/frr.conf"
cat ~/frr-no-overlay/frr.conf

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
echo "Daemons configuration created at ~/frr-no-overlay/daemons"
cat ~/frr-no-overlay/daemons

# Open firewall port for BGP
echo "Opening firewall port 179 for BGP..."
sudo firewall-cmd --zone=libvirt --add-port=179/tcp --permanent || true
sudo firewall-cmd --zone=libvirt --add-port=179/tcp || true

# Run the FRR route reflector container
echo "Starting FRR route reflector container..."
sudo podman rm -f frr || true
sudo podman run -d --name frr \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_ADMIN \
  -v ~/frr-no-overlay/frr.conf:/etc/frr/frr.conf:ro,Z \
  quay.io/frrouting/frr:10.2.1 \
  /usr/lib/frr/bgpd -n -Z -S -f /etc/frr/frr.conf

# Verify the container is running
sleep 5
sudo podman ps | grep frr
echo "FRR route reflector container is running"
EOFSETUP

echo "Creating network operator manifest with NoOverlay transport..."

# Use environment variables for configurable options
OUTBOUND_SNAT="${NO_OVERLAY_OUTBOUND_SNAT:-Enabled}"
ROUTING_MODE="${NO_OVERLAY_ROUTING:-Unmanaged}"

echo "NoOverlay configuration: outboundSNAT=${OUTBOUND_SNAT}, routing=${ROUTING_MODE}"

# Write the network operator configuration to a manifest file
# This will be picked up by dev-scripts during cluster installation
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
    ovnKubernetesConfig:
      routeAdvertisements: Enabled
      defaultNetworkTransport: NoOverlay
      defaultNetworkNoOverlayOptions:
        outboundSNAT: ${OUTBOUND_SNAT}
        routing: ${ROUTING_MODE}
    type: OVNKubernetes
EOF

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
      - address: 192.168.111.1
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - ge: 23
              prefix: 10.128.0.0/14
EOF
cat > "${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  advertisements:
  - PodNetwork
  # Select the FRRConfiguration defined in step-2 with the custom label.
  frrConfigurationSelector:
    matchLabels:
      network: default
  networkSelectors:
  - networkSelectionType: DefaultNetwork
  # The empty nodeSelector selects all nodes. We don't support a network in an overlay and no-overlay hybrid mode.
  nodeSelector: {}
EOF
echo "Network operator manifest created at ${SHARED_DIR}/manifest_network-operator-no-overlay.yaml"
echo "FRR configuration manifest created at ${SHARED_DIR}/manifest_frr-configuration-no-overlay.yaml"
echo "Route advertisements manifest created at ${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml"
cat "${SHARED_DIR}/manifest_network-operator-no-overlay.yaml"
cat "${SHARED_DIR}/manifest_frr-configuration-no-overlay.yaml"
cat "${SHARED_DIR}/manifest_route-advertisements-no-overlay.yaml"


