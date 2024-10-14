#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export STORAGECLASS_LOCATION=${SHARED_DIR}/efs-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

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

ROOT_SECRET_EXIST="yes"
if [[ "$(oc -n kube-system get secret/aws-creds --ignore-not-found)" == "" ]]; then
  echo "Root secret is not exist, temply using the shared secret instead"
  ROOT_SECRET_EXIST="no"
fi

# In all CCO mode manual and some mint mode test clusters doesn't have the root secret
# temply create the root secret using for create efs volume
if [[ "${ROOT_SECRET_EXIST}" == "no" ]]; then
  AWS_AK=$(< "$AWS_SHARED_CREDENTIALS_FILE" grep aws_access_key_id | sed -e 's/aws_access_key_id = //g')
  AWS_SK=$(< "${AWS_SHARED_CREDENTIALS_FILE}" grep aws_secret_access_key | sed -e 's/aws_secret_access_key = //g')
  oc create secret generic aws-creds -n kube-system \
  --from-literal aws_access_key_id="${AWS_AK}" \
  --from-literal aws_secret_access_key="${AWS_SK}"
  /usr/bin/create-efs-volume start --kubeconfig "$KUBECONFIG" --namespace openshift-cluster-csi-drivers
  oc -n kube-system delete secret/aws-creds
else
  /usr/bin/create-efs-volume start --kubeconfig "$KUBECONFIG" --namespace openshift-cluster-csi-drivers
fi

echo "Using storageclass ${STORAGECLASS_LOCATION}"
cat ${STORAGECLASS_LOCATION}

oc create -f ${STORAGECLASS_LOCATION}
echo "Created storageclass from file ${STORAGECLASS_LOCATION}"

oc create -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

echo "Created cluster CSI driver object"

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
    cp /usr/share/aws-efs-csi-driver/ocp-manifest.yaml  ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
    cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
