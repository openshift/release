#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

deploy_frr_external_container() {
  echo "Deploying FRR external container ..."
  clone_frr
 
  pushd "$FRR_TMP_DIR" || exit 1
  kubectl apply -f frr-k8s/charts/frr-k8s/charts/crds/templates/frrk8s.metallb.io_frrconfigurations.yaml
  popd || exit 1
 
  # apply the demo which will deploy an external FRR container that the cluster
  # can peer with acting as BGP (reflector) external gateway
  pushd "${FRR_TMP_DIR}"/frr-k8s/hack/demo || exit 1
  # modify config template to configure neighbors as route reflector clients
  sed -i '/remote-as 64512/a \ neighbor {{ . }} route-reflector-client' frr/frr.conf.tmpl
  ./demo.sh
  popd || exit 1
}

# enable route advertisement with FRR
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

# deploy a frr instance
deploy_frr_external_container

# advertise the pod network
kubectl apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  advertisements:
    podNetwork: true
EOF
