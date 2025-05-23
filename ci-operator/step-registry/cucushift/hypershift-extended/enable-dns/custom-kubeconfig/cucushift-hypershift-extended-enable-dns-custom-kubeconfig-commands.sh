#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_name: $CLUSTER_NAME"
if ! KAS_DNS_NAME=$(oc get "hostedclusters/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath='{.spec.kubeAPIServerDNSName}' 2>/dev/null)
then
    echo "ERROR: HostedCluster '${CLUSTER_NAME}' not found in namespace '${HYPERSHIFT_NAMESPACE}'" >&2
    exit 1
elif [[ -z "${KAS_DNS_NAME}" ]]; then
    echo "ERROR: KubeAPI Server DNS name not configured for '${CLUSTER_NAME}'" >&2
    exit 1
fi

#Check secret with custom-kubeconfig generated in HC anc HCP namespaces
if ! oc get -n "${HYPERSHIFT_NAMESPACE}" secret "${CLUSTER_NAME}-custom-admin-kubeconfig" &>/dev/null; then
    echo "ERROR: Missing required secret '${CLUSTER_NAME}-custom-admin-kubeconfig' in HC namespace '${HYPERSHIFT_NAMESPACE}'" >&2
    exit 1
fi

if ! oc get -n "clusters-${CLUSTER_NAME}" secret custom-admin-kubeconfig &>/dev/null; then
    echo "ERROR: Missing required secret 'custom-admin-kubeconfig' in HCP namespace 'clusters-${CLUSTER_NAME}'" >&2
    exit 1
fi

echo "Cluster secrets validation passed"

#Visit hc with custom kubeconfig
CUSTOM_KUBECONFIG=/tmp/custom_kube
oc get -n "$HYPERSHIFT_NAMESPACE" secret "${CLUSTER_NAME}-custom-admin-kubeconfig" -o jsonpath='{.data.kubeconfig}' | base64 -d > $CUSTOM_KUBECONFIG || exit 1
sleep 5h
oc --kubeconfig $CUSTOM_KUBECONFIG get clusterversion version &>/dev/null || {
    echo "ERROR: Cluster API unreachable with kubeconfig: $CUSTOM_KUBECONFIG" >&2
    exit 1
}
echo "Cluster API endpoint reachable with custom kubeconfig"

rm -rf /tmp/custom_kube
