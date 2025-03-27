#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
source "${SHARED_DIR}/packet-conf.sh"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << 'EOFTOP'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FRR_K8S_VERSION=v0.0.14
FRR_TMP_DIR=$(mktemp -d -u)

AGNHOST_SUBNET_V4=172.20.0.0/16
AGNHOST_SUBNET_V6=2001:db8:2::/64

clone_frr() {
  [ -d "$FRR_TMP_DIR" ] || {
    mkdir -p "$FRR_TMP_DIR" && trap 'rm -rf $FRR_TMP_DIR' EXIT
    pushd "$FRR_TMP_DIR" || exit 1
    git clone --depth 1 --branch $FRR_K8S_VERSION https://github.com/metallb/frr-k8s
    popd || exit 1
  }
}

generate_frr_config() {
    local NODE="$1"  # Get NODE argument
    local OUTPUT_FILE="$2"  # Get output file path argument
    local IFS=' '
    read -ra ips <<< "$NODE"
    local ipv4_list=()
    local ipv6_list=()
    
    # First filter out IPv4 addresses
    for ip in "${ips[@]}"; do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipv4_list+=("$ip")
        else
            ipv6_list+=("$ip")
        fi
    done

    # Write to file using heredoc
    cat > "$OUTPUT_FILE" << EOF
router bgp 64512
 no bgp default ipv4-unicast
 no bgp network import-check

EOF

    # Generate neighbor remote-as section
    for ip in "${ipv4_list[@]}"; do
        echo " neighbor $ip remote-as 64512" >> "$OUTPUT_FILE"
    done
    echo "" >> "$OUTPUT_FILE"

    for ip in "${ipv6_list[@]}"; do
        echo " neighbor $ip remote-as 64512" >> "$OUTPUT_FILE"
    done
    echo "" >> "$OUTPUT_FILE"

    echo " address-family ipv4 unicast" >> "$OUTPUT_FILE"
    echo "  network ${AGNHOST_SUBNET_V4}" >> "$OUTPUT_FILE"
    for ip in "${ipv4_list[@]}"; do
        echo "  neighbor $ip activate" >> "$OUTPUT_FILE"
        echo "  neighbor $ip next-hop-self" >> "$OUTPUT_FILE"
        echo "  neighbor $ip route-reflector-client" >> "$OUTPUT_FILE"
    done
    echo " exit-address-family" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    echo " address-family ipv6 unicast" >> "$OUTPUT_FILE"
    echo "  network ${AGNHOST_SUBNET_V6}" >> "$OUTPUT_FILE"
    for ip in "${ipv6_list[@]}"; do
        echo "  neighbor $ip activate" >> "$OUTPUT_FILE"
        echo "  neighbor $ip next-hop-self" >> "$OUTPUT_FILE"
        echo "  neighbor $ip route-reflector-client" >> "$OUTPUT_FILE"
    done
    echo " exit-address-family" >> "$OUTPUT_FILE"
}

deploy_frr_external_container() {
  echo "Deploying FRR external container ..."
  clone_frr
  # create the frr container with host network
  NODES=$(kubectl get nodes -o jsonpath={.items[*].status.addresses[?\(@.type==\"InternalIP\"\)].address})
  echo $NODES
  FRR_CONFIG=$(mktemp -d -t frr-XXXXXXXXXX)
  generate_frr_config "$NODES" $FRR_CONFIG/frr.conf
  cp "${FRR_TMP_DIR}"/frr-k8s/hack/demo/frr/daemons $FRR_CONFIG
  chmod a+rw $FRR_CONFIG/*

  podman run -d --privileged --network agnhost_net --ip 172.20.0.2 --rm --ulimit core=-1 --name frr --volume "$FRR_CONFIG":/etc/frr quay.io/frrouting/frr:9.1.0
  # attach the frr container to the ostestbm bridge, so it can talk with the OCP nodes.
  podman network connect ostestbm_net frr
  # assign static IP to the interface that connects to the cluster network
  podman exec frr ip addr add dev eth1  192.168.111.3/24
  podman exec frr ip -6 addr add dev eth1  fd2e:6f44:5dd8:c956::3/64
  # remove the default route given by podman, use cluster network gateway as the default route
  podman exec frr ip route del default dev eth0 via 172.20.0.1
  podman exec frr ip route add default dev eth1 via 192.168.111.1
  podman exec frr ip -6 route del default dev eth0 via 2001:db8:2::1
  podman exec frr ip -6 route add default dev eth1 via fd2e:6f44:5dd8:c956::1
  # ipv4 forwarding is enabled by default, we only need to turn on ipv6 forwarding
  podman exec frr sysctl -w net.ipv6.conf.all.forwarding=1
}

deploy_agnhost_container() {
  podman run -d --privileged --name agnhost --network agnhost_net --rm --ip 172.20.0.100 --ip6 2001:db8:2::100 registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8000
  # remove the default route given by podman, use the frr container as the default gateway
  podman exec agnhost ip route del default dev eth0 via 172.20.0.1
  podman exec agnhost ip route add default dev eth0 via 172.20.0.2
  podman exec agnhost ip -6 route del default dev eth0 via 2001:db8:2::1
  podman exec agnhost ip -6 route add default dev eth0 via 2001:db8:2::2
}

podman rm -f frr || true
podman rm -f agnhost || true
podman network rm ostestbm_net || true
podman network rm agnhost_net || true

# create a podman network attached to the cluster network by attaching to the existing ostestbm bridge
podman network create --driver bridge --ipam-driver=none --opt com.docker.network.bridge.name=ostestbm ostestbm_net
# use macvlan to bypass host kernel, ensure the agnhost can only be accessed via the frr container.
ip link add dummy0 type dummy
ip link set dummy0 up
podman network create --driver macvlan -o parent=dummy0 --ipv6 --subnet=${AGNHOST_SUBNET_V4} --subnet=${AGNHOST_SUBNET_V6} agnhost_net

# deploy an agnhost container as an external host for BGP test
deploy_agnhost_container

# deploy a frr instance
deploy_frr_external_container

# enable route advertisement with FRR
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

echo "Waiting for namespace 'openshift-frr-k8s' to be created..."
until kubectl get namespace "openshift-frr-k8s" &> /dev/null; do
  sleep 5
done
echo "Namespace 'openshift-frr-k8s' has been created."

echo "Waiting for daemonset 'frr-k8s' to be created..."
until oc rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m &> /dev/null; do
  sleep 5
done

echo "Waiting for deploy 'frr-k8s-webhook-server' to be created..."
until oc wait -n openshift-frr-k8s deployment frr-k8s-webhook-server --for condition=Available --timeout 2m &> /dev/null; do
  sleep 5
done

# advertise the pod network
oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  networkSelector:
    matchLabels:
      k8s.ovn.org/default-network: ""
  advertisements:
    - "PodNetwork"
EOF
# set up BGP peering with the FRR instance running at hypervisor for both v4 and v6
oc apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: receive-filtered
  namespace: openshift-frr-k8s
spec:
  bgp:
    routers:
    - asn: 64512
      neighbors:
      - address: 192.168.111.3
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V4}
      - address: fd2e:6f44:5dd8:c956::3
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V6}
EOF

CLUSTER_NETWORK_V4="10.128.0.0/14"
ip route add $CLUSTER_NETWORK_V4 via 192.168.111.3 dev ostestbm
iptables -t filter -I FORWARD -s ${CLUSTER_NETWORK_V4} -i ostestbm -j ACCEPT
iptables -t filter -I FORWARD -d ${CLUSTER_NETWORK_V4} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V4} ! -d 192.168.111.1/24 -j MASQUERADE

CLUSTER_NETWORK_V6="fd01::/48"
ip -6 route add $CLUSTER_NETWORK_V6 via fd2e:6f44:5dd8:c956::3 dev ostestbm
ip6tables -t filter -I FORWARD -s ${CLUSTER_NETWORK_V6} -i ostestbm -j ACCEPT
ip6tables -t filter -I FORWARD -d ${CLUSTER_NETWORK_V6} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ip6tables -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V6} ! -d fd2e:6f44:5dd8:c956::1 -j MASQUERADE
EOFTOP
