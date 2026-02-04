#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

STATS_PORT=1937 # Non-default port for metrics. Default is 1936.
CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

# Patch the hostedcluster to use the HostNetwork endpoint publishing strategy.
# This is to cover the case where the ingress controller is configured with specific ports.
# There's no functional change to this scenario, except for different ports.
# See https://issues.redhat.com/browse/OCPSTRAT-2519
function apply_custom_endpoint_publishing_strategy() {
  echo "Patching hostedcluster to use the HostNetwork endpoint publishing strategy"
  cat <<EOF | oc patch "hostedcluster/${CLUSTER_NAME}" -n local-cluster --type=merge --patch-file=/dev/stdin
spec:
  operatorConfiguration:
    ingressOperator:
      endpointPublishingStrategy:
        type: HostNetwork
        hostNetwork:
          httpPort: 80 # Same as default.
          httpsPort: 443 # Same as default.
          protocol: TCP # Same as default.
          statsPort: ${STATS_PORT}
EOF
}

function check_ingress_controller_stats_port() {
  echo "Checking ingress controller stats port"
  oc delete ingresscontroller -n openshift-ingress-operator default
  oc wait --timeout=60s --for=jsonpath='{.spec.endpointPublishingStrategy.hostNetwork.statsPort}'=${STATS_PORT} ingresscontroller/default -n openshift-ingress-operator
}

apply_custom_endpoint_publishing_strategy

if [[ ! -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  echo "Nested kubeconfig not found, exiting..."
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
check_ingress_controller_stats_port
