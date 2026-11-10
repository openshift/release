#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_CSI_DRIVER_NAME="secrets-store.csi.k8s.io"
export E2E_PROVIDER_DAEMONSET_LOCATION=${SHARED_DIR}/e2e-provider.yaml
export E2E_PROVIDER_NAMESPACE=openshift-cluster-csi-drivers
export E2E_PROVIDER_SERVICE_ACCOUNT=csi-secrets-store-e2e-provider-sa

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Deleting E2E Provider DaemonSet from file ${E2E_PROVIDER_DAEMONSET_LOCATION}"
oc delete -f ${E2E_PROVIDER_DAEMONSET_LOCATION}
echo "Deleted E2E Provider DaemonSet from file ${E2E_PROVIDER_DAEMONSET_LOCATION}"

echo "Deleting E2E Provider ServiceAccount"
oc delete serviceaccount -n ${E2E_PROVIDER_NAMESPACE} ${E2E_PROVIDER_SERVICE_ACCOUNT}
echo "Deleted E2E Provider ServiceAccount"

echo "Deleting ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
oc delete clustercsidriver ${CLUSTER_CSI_DRIVER_NAME}
echo "Deleted ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
