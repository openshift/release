#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

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

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
HOSTED_CP=${HOSTED_CP:-false}
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

NETWORK_TYPE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json  | jq -r '.network.type')
HOSTED_CP=$(rosa describe cluster -c "${CLUSTER_ID}" -o json  | jq -r '.hypershift.enabled')

if [[ "$HOSTED_CP" == "true" ]] && [[ "${NETWORK_TYPE}" == "Other" ]]; then
  cilium_ns=$(oc get ns cilium --ignore-not-found)
  if [[ -z "$cilium_ns" ]]; then
       oc create ns cilium
  fi
  CILIUM_VERSION="1.14.5"
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
  ' |  envsubst > /tmp/ciliumconfig.json

  oc apply -f /tmp/ciliumconfig.json
  oc wait --for=condition=Ready pod -n cilium --all --timeout=5m
fi
