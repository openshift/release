#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_CSI_DRIVER_NAME="smb.csi.k8s.io"
export SMB_SERVER_MANIFEST=${SHARED_DIR}/samba-server.yaml

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

echo "Deleting ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
oc delete clustercsidriver ${CLUSTER_CSI_DRIVER_NAME}
echo "Deleted ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"

echo "Deleting ${SMB_SERVER_MANIFEST}"
oc delete -f ${SMB_SERVER_MANIFEST}
echo "Deleted ${SMB_SERVER_MANIFEST}"
