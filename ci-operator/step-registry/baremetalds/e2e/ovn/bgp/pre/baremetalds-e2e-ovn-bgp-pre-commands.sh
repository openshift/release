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
set -x

FRR_K8S_VERSION=v0.0.14
FRR_TMP_DIR=$(mktemp -d -u)

AGNHOST_SUBNET_V4=172.20.0.0/16
AGNHOST_SUBNET_V6=2001:db8:2::/64

SUDO=
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
fi

CLI="$SUDO podman"
if ! command -v "podman"; then
    CLI="$SUDO docker"
fi
echo "Container CLI is: $CLI"

KCLI="kubectl"
if ! command -v $KCLI; then
    KCLI="oc"
fi

IP="$SUDO ip"
IPTABLES="$SUDO iptables"
IP6TABLES="$SUDO ip6tables"

source ~/dev-scripts-additional-config

clone_frr() {
  [ -d "$FRR_TMP_DIR" ] || {
    mkdir -p "$FRR_TMP_DIR" && trap 'rm -rf $FRR_TMP_DIR' EXIT
    pushd "$FRR_TMP_DIR" || exit 1
    git clone --depth 1 --branch $FRR_K8S_VERSION https://github.com/metallb/frr-k8s
    popd || exit 1
  }
}

generate_frr_config() {
    local output_file="$1"  # Get output file path argument
    local -n neighbors=$2

    echo "log file /etc/frr/frr.log debugging" > "$output_file"
    
    for vrf in "${!neighbors[@]}"; do
      local ipv4_list=()
      local ipv6_list=()
      # First filter out IPv4 addresses
      for ip in ${neighbors[$vrf]}; do
          if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              ipv4_list+=("$ip")
          else
              ipv6_list+=("$ip")
          fi
      done
      
      [ "default" = "$vrf" ] && {
        echo "router bgp 64512" >> "$output_file"
      } || {
        echo "router bgp 64512 vrf $vrf" >> "$output_file"
      }

      # Generate neighbor remote-as section
      for ip in "${ipv4_list[@]}"; do
          echo " neighbor $ip remote-as 64512" >> "$output_file"
      done
      echo "" >> "$output_file"

      for ip in "${ipv6_list[@]}"; do
          echo " neighbor $ip remote-as 64512" >> "$output_file"
      done
      echo "" >> "$output_file"

      echo " address-family ipv4 unicast" >> "$output_file"
      echo "  network ${AGNHOST_SUBNET_V4}" >> "$output_file"
      for ip in "${ipv4_list[@]}"; do
          echo "  neighbor $ip activate" >> "$output_file"
          echo "  neighbor $ip next-hop-self" >> "$output_file"
          echo "  neighbor $ip route-reflector-client" >> "$output_file"
      done
      echo " exit-address-family" >> "$output_file"
      echo "" >> "$output_file"

      echo " address-family ipv6 unicast" >> "$output_file"
      echo "  network ${AGNHOST_SUBNET_V6}" >> "$output_file"
      for ip in "${ipv6_list[@]}"; do
          echo "  neighbor $ip activate" >> "$output_file"
          echo "  neighbor $ip next-hop-self" >> "$output_file"
          echo "  neighbor $ip route-reflector-client" >> "$output_file"
      done
      echo " exit-address-family" >> "$output_file"
    done
}

deploy_frr_external_container() {
  echo "Deploying FRR external container ..."
  clone_frr
  
  local frr_config=$(mktemp -d -t frr-XXXXXXXXXX)
  local -n vrfs=$1
  generate_frr_config ${frr_config}/frr.conf vrfs
  
  cp "${FRR_TMP_DIR}"/frr-k8s/hack/demo/frr/daemons $frr_config
  chmod a+rw ${frr_config}/*

  # cleanup
  $CLI rm -f frr || true
  $CLI network rm -f ostestbm_net || true
  
  # create a $CLI network attached to the cluster network by attaching to the existing ostestbm bridge
  $CLI network create --driver bridge --ipam-driver=none --opt com.docker.network.bridge.name=ostestbm ostestbm_net

  $CLI run -d --rm --privileged --ulimit core=-1 --network ostestbm_net --name frr --volume "$frr_config":/etc/frr quay.io/frrouting/frr:9.1.0
  # ipv4 forwarding is enabled by default, we only need to turn on ipv6 forwarding
  $CLI exec frr sysctl -w net.ipv6.conf.all.forwarding=1
  
  # attach the frr container to the ostestbm bridge, so it can talk with the OCP nodes.
  # use primary network gateway as the default route
  $CLI exec frr ip address add dev eth0 192.168.111.3/24
  $CLI exec frr ip route add default dev eth0 via 192.168.111.1
  $CLI exec frr ip -6 address add dev eth0 fd2e:6f44:5dd8:c956::3/64
  $CLI exec frr ip -6 route add default dev eth0 via fd2e:6f44:5dd8:c956::1

  # eth1 attaches to agnhost_net
  $CLI network connect agnhost_net frr
  $CLI exec frr ip address add dev eth1 172.20.0.2/16
  $CLI exec frr ip -6 address add dev eth1 2001:db8:2::2/64
  
  # setup VRFs for extra networks
  seq=2 
  for vrf in "${!vrfs[@]}"; do
    [ "default" = "$vrf" ] && continue

    # cleanup
    $CLI network rm -f ${vrf}_net || true
    
    # create VRF
    $CLI exec frr ip link add $vrf type vrf table $seq
    $CLI exec frr ip link set dev $vrf up
    $CLI exec frr ip route add table $seq unreachable default metric 4278198272
    $CLI exec frr ip -6 route add table $seq unreachable default dev lo metric 4278198272

    # create a $CLI network attached to the extra network
    $CLI network create --driver bridge --ipam-driver=none --opt com.docker.network.bridge.name=${vrf} ${vrf}_net

    # attach the frr container to the extra network and add to VRF
    local subnet_v4_var=${vrf^^}_NETWORK_SUBNET_V4
    local subnet_v6_var=${vrf^^}_NETWORK_SUBNET_V6
    local ip=${!subnet_v4_var/\.0\//.3\/}
    local ip6=${!subnet_v6_var/::\//::3\/}
    $CLI network connect ${vrf}_net frr
    $CLI exec frr ip link set dev eth$seq master $vrf
    $CLI exec frr ip address add dev eth$seq $ip
    $CLI exec frr ip -6 address add dev eth$seq $ip6

    ((seq+=1))

    # attach the frr container to the corresponding agnhost network and add to VRF
    $CLI network connect agnhost_${vrf}_net frr
    $CLI exec frr ip link set dev eth$seq master $vrf
    $CLI exec frr ip address add dev eth$seq 172.20.0.2/16
    $CLI exec frr ip -6 address add dev eth$seq 2001:db8:2::2/64

    ((seq+=1))
  done
}

DUMMY=0
deploy_agnhost_container() {
  local name=$1
  local net=${name}_net
  local dummy=dummy$DUMMY
  ((DUMMY+=1))
 
  # cleanup 
  $CLI rm -f $name || true
  $CLI network rm -f $net
  $IP link del $dummy || true
 
  $IP link add $dummy type dummy
  $IP link set $dummy up
  $CLI network create --driver macvlan --ipam-driver=none -o parent=$dummy --ipv6 $net
  
  $CLI run -d --privileged --name $name --hostname $name --network $net --rm registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8000
  $CLI exec $name ip address add dev eth0 172.20.0.100/16
  $CLI exec $name ip route add default dev eth0 via 172.20.0.2
  $CLI exec $name ip -6 address add dev eth0 2001:db8:2::100/64
  $CLI exec $name ip -6 route add default dev eth0 via 2001:db8:2::2
}

# Set ipForwarding=Global for LGW. This a workaround until OCPBUGS-42993 is fixed.
local_gateway_mode=$(oc get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}')
if [ "$local_gateway_mode" = "true" ]; then
    echo "cluster is in local gateway mode"
    ip_forwarding=$(oc get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}')
    if [ "$ip_forwarding" != "Global" ]; then
      echo "Setting ip_forwarding to Global..."
      oc patch Network.operator.openshift.io cluster --type=merge \
        -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'

      echo "Waiting for network operator to start applying changes..."
      for _ in {1..30}; do
        if [[ $(oc get co network -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}') == "True" ]]; then
          echo "Network operator started applying changes"
          break
        fi
        sleep 10
      done
      echo "Waiting for network operator to complete changes..."
      for _ in {1..30}; do
        if [[ $(oc get co network -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}') == "False" ]]; then
          echo "Network configuration completed successfully"
          break
        fi
        sleep 10
      done
    fi
fi

# we will potentially deploy multiple networks, each on its own VRF
declare -A vrf_neighbors
vrf_neighbors["default"]=$($KCLI get nodes -o jsonpath={.items[*].status.addresses[?\(@.type==\"InternalIP\"\)].address})

# deploy an agnhost container isolated on a macvlan network
deploy_agnhost_container agnhost

# also for an extra network ...
EXTRA_NETWORK=$(echo ${EXTRA_NETWORK_NAMES:-} | awk '{print $1;}')
if [ -n "$EXTRA_NETWORK" ]; then   
  # deploy an extra agnhost container for an extra network, isolated on its own macvlan network
  deploy_agnhost_container agnhost_$EXTRA_NETWORK
  
  # track this networks neighbors
  vrf_neighbors["$EXTRA_NETWORK"]=$(sudo virsh net-dumpxml $EXTRA_NETWORK | xmllint --xpath '/network//host/@ip' - | cut -d '=' -f2 | tr -d \" | xargs)
fi

# deploy a frr instance
# connects, on its default VRF, to default agnhost container macvlan network and the default ostestbm cluster network
# connects, on a specific VRF per extra cluster network, to the corresponding agnhost container macvlan network and that extra cluster network  
deploy_frr_external_container vrf_neighbors

# enable route advertisement with FRR
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

echo "Waiting for namespace 'openshift-frr-k8s' to be created..."
until $KCLI get namespace "openshift-frr-k8s" &> /dev/null; do
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

# set up BGP peering of the cluster with the external FRR instance container
# peer is setup on the default VRF and also on each extra network VRF
for network in "${!vrf_neighbors[@]}"; do
  label="network: ${network}"
  [ "default" = "$network" ] && {
    name=receive-filtered
    vrf=
    ip=192.168.111.3
    ip6=fd2e:6f44:5dd8:c956::3
    network_selector=$(cat <<EOF
    - networkSelectionType: DefaultNetwork  
EOF
)
  } || {
    subnet_v4_var=${network^^}_NETWORK_SUBNET_V4
    subnet_v6_var=${network^^}_NETWORK_SUBNET_V6
    ip=${!subnet_v4_var/\.0\/*/.3}
    ip6=${!subnet_v6_var/::\/*/::3}
    name=receive-filtered-$network
    vrf="vrf: ${network}"
    network_selector=$(cat <<EOF
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            ${label}
EOF
)
  }

  oc apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: ${name}
  namespace: openshift-frr-k8s
  labels:
    ${label}
spec:
  bgp:
    routers:
    - asn: 64512
      ${vrf}
      neighbors:
      - address: ${ip}
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V4}
      - address: ${ip6}
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V6}
EOF

# advertise the network
  oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: ${network}
spec:
  nodeSelector: {}
  networkSelectors:
${network_selector}
  frrConfigurationSelector:
    matchLabels:
      ${label}
  advertisements:
    - "PodNetwork"
EOF
done

CLUSTER_NETWORK_V4="10.128.0.0/14"
$IP route add $CLUSTER_NETWORK_V4 via 192.168.111.3 dev ostestbm || true
$IPTABLES -t filter -I FORWARD -s ${CLUSTER_NETWORK_V4} -i ostestbm -j ACCEPT
$IPTABLES -t filter -I FORWARD -d ${CLUSTER_NETWORK_V4} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
$IPTABLES -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V4} ! -d 192.168.111.1/24 -j MASQUERADE

CLUSTER_NETWORK_V6="fd01::/48"
$IP -6 route add $CLUSTER_NETWORK_V6 via fd2e:6f44:5dd8:c956::3 dev ostestbm || true
$IP6TABLES -t filter -I FORWARD -s ${CLUSTER_NETWORK_V6} -i ostestbm -j ACCEPT
$IP6TABLES -t filter -I FORWARD -d ${CLUSTER_NETWORK_V6} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
$IP6TABLES -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V6} ! -d fd2e:6f44:5dd8:c956::1 -j MASQUERADE
EOFTOP
