#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Set the IP address of Minio running on virthost to prevent flakes due
# to the hostname being unresolvable. This value is calculated in
# baremetalds-devscripts-setup-commands.sh as ${EXTERNAL_SUBNET_V4%.*}.1.
VIRTHOST_IP="192.168.111.1"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/redhat-user-workloads/ocp-art-tenant/oadp-hypershift-oadp-plugin-main:main}"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
cat <<EOF > /tmp/miniocred
[default]
aws_access_key_id=admin
aws_secret_access_key=admin123
EOF

oc create secret generic cloud-credentials -n openshift-adp --from-file cloud=/tmp/miniocred

cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-sample
  namespace: openshift-adp
spec:
  backupImages: false
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      defaultPlugins:
        - openshift
        - aws
        - kubevirt
        - csi
      customPlugins:
        - name: hypershift-oadp-plugin
          image: ${OADP_PLUGIN_IMAGE}
      noDefaultBackupLocation: true
      logLevel: debug
EOF

echo "Waiting for velero Deployment to be ready..."
timeout 5m bash -c 'until oc get deployment/velero -n openshift-adp >/dev/null 2>&1; do sleep 5; done'
oc rollout status deployment/velero -n openshift-adp --timeout=300s

echo "Waiting for node-agent DaemonSet to be ready..."
timeout 10m bash -c 'until oc get daemonset/node-agent -n openshift-adp >/dev/null 2>&1; do sleep 5; done'
oc rollout status daemonset/node-agent -n openshift-adp --timeout=600s

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")

echo "Creating BackupStorageLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: aws
  objectStorage:
    bucket: oadp-backup
    prefix: hcp
  credential:
    name: cloud-credentials
    key: cloud
  config:
    region: minio
    s3ForcePathStyle: "true"
    s3Url: "http://${VIRTHOST_IP}:9000"
    insecureSkipTLSVerify: "true"
    profile: default
EOF

echo "Creating VolumeSnapshotLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: VolumeSnapshotLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: aws
  credential:
    name: cloud-credentials
    key: cloud
  config:
    region: minio
    profile: default
EOF

timeout 5m bash -c "until [[ \$(oc get dataProtectionApplication/dpa-sample -n openshift-adp -o jsonpath='{.status.conditions[?(@.type==\"Reconciled\")].status}' 2>/dev/null) == \"True\" ]]; do sleep 15; done"
timeout 5m bash -c "until [[ \$(oc get backupStorageLocation/${CLUSTER_NAME} -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null) == \"Available\" ]]; do sleep 15; done"
