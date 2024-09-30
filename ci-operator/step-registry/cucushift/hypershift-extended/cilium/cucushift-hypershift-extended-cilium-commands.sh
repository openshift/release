#!/bin/bash

set -xeuo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

set_proxy

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

# for rosa kubeadmin kubeconfig
if [[ -f "${SHARED_DIR}/kubeconfig.kubeadmin" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig.kubeadmin"
fi


cilium_ns=$(oc get ns cilium --ignore-not-found)
if [[ -z "$cilium_ns" ]]; then
  oc create ns cilium
fi

oc label ns cilium security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

# apply isovalent cilium CNI
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-03-cilium-ciliumconfigs-crd.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00000-cilium-namespace.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00001-cilium-olm-serviceaccount.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00002-cilium-olm-deployment.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00003-cilium-olm-service.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00004-cilium-olm-leader-election-role.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00005-cilium-olm-role.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00006-leader-election-rolebinding.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00007-cilium-olm-rolebinding.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00008-cilium-cilium-olm-clusterrole.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00009-cilium-cilium-clusterrole.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00010-cilium-cilium-olm-clusterrolebinding.yaml"
oc apply -f "https://raw.githubusercontent.com/isovalent/olm-for-cilium/main/manifests/cilium.v${CILIUM_VERSION}/cluster-network-06-cilium-00011-cilium-cilium-clusterrolebinding.yaml"

PODCIDR=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
HOSTPREFIX=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].hostPrefix}')
export PODCIDR=$PODCIDR
export HOSTPREFIX=$HOSTPREFIX

echo '
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: cilium
  namespace: cilium
spec:
  debug:
    enabled: true
  k8s:
    requireIPv4PodCIDR: true
  logSystemLoad: true
  bpf:
    preallocateMaps: true
  etcd:
    leaseTTL: 30s
  ipv4:
    enabled: true
  ipv6:
    enabled: false
  identityChangeGracePeriod: 0s
  ipam:
    mode: "cluster-pool"
    operator:
      clusterPoolIPv4PodCIDRList:
        - "${PODCIDR}"
      clusterPoolIPv4MaskSize: "${HOSTPREFIX}"
  nativeRoutingCIDR: "${PODCIDR}"
  endpointRoutes: {enabled: true}
  clusterHealthPort: 9940
  tunnelPort: 4789
  cni:
    binPath: "/var/lib/cni/bin"
    confPath: "/var/run/multus/cni/net.d"
    chainingMode: portmap
  prometheus:
    serviceMonitor: {enabled: false}
  hubble:
    tls: {enabled: false}
  sessionAffinity: true
' | envsubst > /tmp/ciliumconfig.json

oc apply -f /tmp/ciliumconfig.json
oc wait --for=condition=Ready pod -n cilium --all --timeout=5m