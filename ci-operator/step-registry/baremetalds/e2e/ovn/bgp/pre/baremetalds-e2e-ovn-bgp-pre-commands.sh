#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
source "${SHARED_DIR}/packet-conf.sh"
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOFTOP'
FRR_K8S_VERSION=v0.0.14
FRR_TMP_DIR=$(mktemp -d -u)

clone_frr() {
  [ -d "$FRR_TMP_DIR" ] || {
    mkdir -p "$FRR_TMP_DIR" && trap 'rm -rf $FRR_TMP_DIR' EXIT
    pushd "$FRR_TMP_DIR" || exit 1
    git clone --depth 1 --branch $FRR_K8S_VERSION https://github.com/metallb/frr-k8s
    popd || exit 1
  }
}

deploy_frr_external_container() {
  echo "Deploying FRR external container ..."
  clone_frr
 
  # apply the demo which will deploy an external FRR container that the cluster
  # can peer with acting as BGP (reflector) external gateway
  pushd "${FRR_TMP_DIR}"/frr-k8s/hack/demo || exit 1
  # modify config template to configure neighbors as route reflector clients
  sed -i '/remote-as 64512/a \ neighbor {{ . }} route-reflector-client' frr/frr.conf.tmpl
  # create the frr container with host network
  sed -i 's/kind/host/' demo.sh
  ./demo.sh
  popd || exit 1
}

sudo dnf install -y podman-docker golang

# deploy a frr instance
deploy_frr_external_container

# enable route advertisement with FRR
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

echo "Waiting for namespace 'openshift-frr-k8s' to be created..."
until kubectl get namespace "openshift-frr-k8s" &> /dev/null; do
  sleep 5
done
echo "Namespace 'openshift-frr-k8s' has been created."

oc wait -n openshift-frr-k8s deployment frr-k8s-webhook-server --for condition=Available --timeout 2m
oc rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m

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
      - address: 192.168.111.1
        asn: 64512
        toReceive:
          allowed:
            mode: filtered
EOF
EOFTOP
