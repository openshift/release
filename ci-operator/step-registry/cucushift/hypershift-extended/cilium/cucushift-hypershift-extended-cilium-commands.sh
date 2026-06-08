#!/bin/bash

set -euo pipefail

CILIUM_VERSION=${CILIUM_VERSION:-"1.19.4"}
CILIUM_CLI_VERSION=${CILIUM_CLI_VERSION:-"0.19.2"}

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

set -x

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

# for rosa kubeadmin kubeconfig
if [[ -f "${SHARED_DIR}/kubeconfig.kubeadmin" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig.kubeadmin"
fi

mkdir -p /tmp/bin
export PATH=/tmp/bin:$PATH
curl --fail --retry 3 -sS -L "https://github.com/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" | tar -xzC /tmp/bin/
chmod +x /tmp/bin/cilium

PODCIDR=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
HOSTPREFIX=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].hostPrefix}')
export PODCIDR=$PODCIDR
export HOSTPREFIX=$HOSTPREFIX

oc get ns cilium || oc create ns cilium
oc adm policy add-scc-to-user privileged -z cilium -n cilium
oc adm policy add-scc-to-user privileged -z cilium-operator -n cilium
oc adm policy add-scc-to-user privileged -z cilium-envoy -n cilium

# Overriding the default 0.3.1 cniVersion to workaround https://redhat.atlassian.net/browse/OCPBUGS-86033
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-cni-override
  namespace: cilium
data:
  cilium-override.conf: |
    {
      "cniVersion": "0.4.0",
      "name": "portmap",
      "plugins": [
        {
            "type": "cilium-cni",
            "enable-debug": true,
            "log-file": "/var/run/cilium/cilium-cni.log"
        },
        {
          "type": "portmap",
          "capabilities": {"portMappings": true}
        }
      ]
    }
EOF

# Note: In order to test with a development version, use:
# --repository oci://quay.io/cilium-charts-dev/cilium --version <version>
# where <version> is a tag from https://quay.io/repository/cilium-charts-dev/cilium
cilium install \
    --namespace cilium \
    --version "${CILIUM_VERSION}" \
    --set debug.enabled=true \
    --set k8s.requireIPv4PodCIDR=true \
    --set logSystemLoad=true \
    --set ipv6.enabled=false \
    --set identityChangeGracePeriod=0s \
    --set ipam.mode=cluster-pool \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={${PODCIDR}}" \
    --set ipam.operator.clusterPoolIPv4MaskSize=${HOSTPREFIX} \
    --set ipv4NativeRoutingCIDR=${PODCIDR} \
    --set cni.binPath=/var/lib/cni/bin \
    --set cni.confPath=/var/run/multus/cni/net.d \
    --set sessionAffinity=true \
    --set endpointRoutes.enabled="true" \
    --set tunnelPort=4789 \
    --set clusterHealthPort=9940 \
    --set socketLB.enabled=true \
    --set cni.readCniConf=/etc/cilium-cni/cilium-override.conf \
    --set extraVolumes[0].name=cni-override \
    --set extraVolumes[0].configMap.name=cilium-cni-override \
    --set extraVolumeMounts[0].name=cni-override \
    --set extraVolumeMounts[0].mountPath=/etc/cilium-cni

cilium status --namespace cilium --wait