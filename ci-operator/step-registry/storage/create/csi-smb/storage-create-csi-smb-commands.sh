#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_CSI_DRIVER_NAME="smb.csi.k8s.io"
export SMB_SERVER_MANIFEST=${SHARED_DIR}/samba-server.yaml
export TEST_MANIFEST=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
export OPERATOR_E2E_DIR=/go/src/github.com/openshift/csi-operator/test/e2e/samba

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

echo "Copying test manifest from csi-operator repo"
cp ${OPERATOR_E2E_DIR}/manifest.yaml ${TEST_MANIFEST}
echo "Using ${TEST_MANIFEST}"
cat ${TEST_MANIFEST}

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
    cp test/e2e/samba/ocp-manifest.yaml ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
    cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

echo "Copying samba-server manifest from csi-operator repo"
cp ${OPERATOR_E2E_DIR}/samba-server.yaml ${SMB_SERVER_MANIFEST}
echo "Using ${SMB_SERVER_MANIFEST}"
cat ${SMB_SERVER_MANIFEST}
oc apply -f ${SMB_SERVER_MANIFEST}

echo "Waiting for samba-server to be ready"
SAMBA_GET_ARGS="-n samba-server samba"
OC_WAIT_ARGS="--for=jsonpath=.status.readyReplicas=1 --timeout=300s"
if ! oc wait statefulset ${SAMBA_GET_ARGS} ${OC_WAIT_ARGS}; then
	oc describe statefulset ${SAMBA_GET_ARGS}
	oc get statefulset ${SAMBA_GET_ARGS} -o yaml
	echo "Wait failed, samba-server did not reach Ready state"
	exit 1
fi
oc get pods -n samba-server
echo "samba-server is ready"

echo "Creating ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: ${CLUSTER_CSI_DRIVER_NAME}
spec:
  managementState: Managed
EOF
echo "Created ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
