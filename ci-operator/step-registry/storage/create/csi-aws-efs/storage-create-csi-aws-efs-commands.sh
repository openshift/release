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

# TODO: Consider use the test manifest from source repo 
#  Research whether we could also add the cross account volume create logic to create-efs-volume tool
if [[ ${ENABLE_CROSS_ACCOUNT} == "yes" ]]; then
  echo "Skip efs volume create since ENABLE_CROSS_ACCOUNT set to yes"
  cat <<EOF > "${MANIFEST_LOCATION}"
StorageClass:
  FromExistingClassName: efs-sc
SnapshotClass:
  FromName: true
DriverInfo:
  Name: efs.csi.aws.com
  SupportedSizeRange:
    Min: 1Gi
    Max: 64Ti
  Capabilities:
    persistence: true
    fsGroup: false
    block: false
    exec: true
    volumeLimits: false
    controllerExpansion: false
    nodeExpansion: false
    snapshotDataSource: false
    RWX: true
    topology: false
    multiplePVsSameID: true
EOF
else
  ARG=(--kubeconfig "$KUBECONFIG" --local-aws-creds=true --namespace openshift-cluster-csi-drivers)
  if [[ ${EFS_ENABLE_SINGLE_ZONE} == "true" ]]; then
    ZONE_NAME=$(oc get node -l node-role.kubernetes.io/worker \
      -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}')
    ARG+=(--single-zone="$ZONE_NAME")
  fi
  /usr/bin/create-efs-volume start "${ARG[@]}"
  echo "Using storageclass ${STORAGECLASS_LOCATION}"
  cat ${STORAGECLASS_LOCATION}

  oc create -f ${STORAGECLASS_LOCATION}
  echo "Created storageclass from file ${STORAGECLASS_LOCATION}"
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

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
    cp /usr/share/aws-efs-csi-driver/ocp-manifest.yaml  ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
    cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
