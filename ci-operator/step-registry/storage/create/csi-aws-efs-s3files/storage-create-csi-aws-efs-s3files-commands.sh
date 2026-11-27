#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export STORAGECLASS_LOCATION="${SHARED_DIR}/s3files-sc.yaml"
export MANIFEST_LOCATION="${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CSI_DRIVER_NAMESPACE="openshift-cluster-csi-drivers"
CSI_DRIVER_SECRETS="aws-efs-cloud-credentials node-aws-efs-cloud-credentials"
CSI_DRIVER_SECRETS_TIMEOUT="${CSI_DRIVER_SECRETS_TIMEOUT:-600}"

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

oc create -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

echo "Created cluster CSI driver object"

# The operator only creates these CredentialsRequests once the ClusterCSIDriver is
# Managed, and cloud-credential-operator then provisions their secrets asynchronously.
# "/usr/bin/volume-create s3 create" below needs the Secret (and IAM role in AWS) to exist.
echo "Waiting up to ${CSI_DRIVER_SECRETS_TIMEOUT}s for the EFS CSI driver credentials in ${CSI_DRIVER_NAMESPACE}"
deadline=$((SECONDS + CSI_DRIVER_SECRETS_TIMEOUT))
for SECRET in ${CSI_DRIVER_SECRETS}; do
    until oc get secret "${SECRET}" -n "${CSI_DRIVER_NAMESPACE}" >/dev/null 2>&1; do
        if [ "${SECONDS}" -ge "${deadline}" ]; then
            echo "Timed out waiting for secret ${SECRET} in namespace ${CSI_DRIVER_NAMESPACE}"
            oc get clustercsidriver efs.csi.aws.com -o yaml || true
            oc get credentialsrequests -n openshift-cloud-credential-operator || true
            oc get secrets -n "${CSI_DRIVER_NAMESPACE}" || true
            exit 1
        fi
        sleep 5
    done
    echo "Found secret ${SECRET}"
done

/usr/bin/volume-create s3 create --kubeconfig "${KUBECONFIG}" --local-aws-creds=true
echo "Using storageclass ${STORAGECLASS_LOCATION}"
cat "${STORAGECLASS_LOCATION}"

oc create -f "${STORAGECLASS_LOCATION}"
echo "Created storageclass from file ${STORAGECLASS_LOCATION}"

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]; then
    # S3 Files test manifests, see test/e2e/aws-s3files in openshift/csi-operator.
    # The image also ships the EFS ones in /usr/share/aws-efs-csi-driver, do not use them.
    ocp_dir="/usr/share/aws-s3files-csi-driver"
    ocp_src="${ocp_dir}/ocp-manifest.yaml"
    ocp_dest="${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}"
    if [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ] && [ -f "${ocp_dir}/ocp-manifest-long.yaml" ]; then
        ocp_src="${ocp_dir}/ocp-manifest-long.yaml"
    fi
    if [ ! -f "${ocp_src}" ]; then
        echo "ERROR: OCP specific manifest ${ocp_src} not found in the image" >&2
        exit 1
    fi
    cp "${ocp_src}" "${ocp_dest}"
    echo "Using OCP specific manifest ${ocp_src} as ${ocp_dest}:"
    cat "${ocp_dest}"
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat "${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
