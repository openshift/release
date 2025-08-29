#!/bin/bash
set -e
set -u
set -o pipefail
set -x
if [[ ${OVN_IPV4_ENABLED} == "false" ]]; then
  echo "SKIP ....."
  exit 0
fi

if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_name: $CLUSTER_NAME"

# Config hostedCluster.spec.configuration.apiServer.ServingCerts.namedCertificates 
JSON_PATCH=$(cat <<EOF
{
  "spec": {
      "operatorConfiguration": {
          "clusterNetworkOperator": {
              "ovnKubernetesConfig": {
                  "namedCertificates": {
                        "internalJoinSubnet": "100.99.0.0/16"
                        },
                        "internalTransitSwitchSubnet": "100.69.0.0/16"
                        }
                    }
                  ]
              }
          }
      }
  }
}
EOF
)
if ! oc patch hc/$CLUSTER_NAME  -n $HYPERSHIFT_NAMESPACE --type=merge -p "$JSON_PATCH" --request-timeout=2m; then
  echo "Failed to apply the patch to configure HC"
  exit 1
else
  echo "Apply the patch to configure HC successfully"
fi

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
echo "Wait until the ovn-kubernetes pods are restarted"
timeout 600s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes

 echo "Check cno ovnKubernetesConfig"
internal_join_subnet=$(oc get networks.operator.openshift.io cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipv4.internalJoinSubnet}')
internal_transit_switch_subnet=$(oc get networks.operator.openshift.io cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipv4.internalTransitSwitchSubnet}')
echo "internalJoinSubnet: $internal_join_subnet"
echo "internalTransitSwitchSubnet: $internal_transit_switch_subnet"
if [ "$internal_join_subnet" != "100.99.0.0/16" ]; then
    echo "Error: internalJoinSubnet is misconfigured"
    exit 1
fi
if [ "$iinternal_transit_switch_subnet" != "100.69.0.0/16" ]; then
    echo "Error: internalTransitSwitchSubnet is misconfigured"
    exit 1
fi
echo "Internal OVN IPV4 Subnets is configured in cno successfully"

source "${SHARED_DIR}/ovn-utils.sh"
# the node annotation will be a specific IP address in the range of the configured subnet, so using wildcard
# matching on the last two octets
check_annotation_on_nodes "k8s.ovn.org/node-gateway-router-lrp-ifaddr" "ipv4" "100\.99\.[0-9]+\.[0-9]+/16"
check_annotation_on_nodes "k8s.ovn.org/node-transit-switch-port-ifaddr" "ipv4" "100\.69\.[0-9]+\.[0-9]+/16"
