#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Setup Bastion
  ## Change default gateway to Bastion host
  ## Host Netserver at $EXTERNAL_SERVER_ADDRESS

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

# shellcheck disable=SC2087
if [ "${NETWORK_WORKLOAD}" == "netperf-external" ]; then
    ssh ${SSH_ARGS} root@"${bastion}" bash -s <<EOF
        ip link add name dummy0 type dummy || true
        ip link set dummy0 up
        ip addr add ${EXTERNAL_SERVER_ADDRESS}/24 dev dummy0 || true
        podman run -d --rm --network=host quay.io/cloud-bulldozer/k8s-netperf:latest netserver -D -L ${EXTERNAL_SERVER_ADDRESS}
EOF
fi

# shellcheck disable=SC2087
if [ "${NETWORK_WORKLOAD}" == "udn-bgp" ]; then
    ssh ${SSH_ARGS} root@"${bastion}" bash -s <<EOF
        export KUBECONFIG=/root/vmno/kubeconfig
        oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
        sleep 60
        oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=10m
        oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=15m

	# Cleanup any stale resources
        podman stop frr >/dev/null 2>&1 || true
        podman rm -f frr >/dev/null 2>&1 || true
        sleep 5
	ip -o link show | awk -F': ' '{print \$2}' | grep '^dummy' | xargs -I {} sudo ip link delete {}
	ip route show proto bgp | grep '^40\.' | awk '{print \$1}' | xargs -I {} ip route del {}
        rm -rf ~/frr-k8s
        sleep 5

        git clone -b ovnk-bgp https://github.com/jcaamano/frr-k8s
        cd ~/frr-k8s/hack/demo;  ./demo.sh; cd -
        oc apply -n openshift-frr-k8s -f ~/frr-k8s/hack/demo/configs/receive_all.yaml
        sleep 5
        podman exec -u root frr vtysh -c "conf t" -c "router bgp 64512" -c "redistribute static" -c "redistribute connected" -c "end" -c "write" 2>/dev/null
        rm -rf ~/frr-k8s
EOF
fi
