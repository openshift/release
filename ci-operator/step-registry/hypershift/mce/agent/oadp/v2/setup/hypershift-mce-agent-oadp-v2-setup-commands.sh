#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# OADP is installed on the management cluster (kubeconfig). The resources being backed up
# (hostedcluster, nodepool, local-cluster namespaces) are management cluster resources.
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Deploy the oadp-helper pod on the hosted cluster so the hypershift-oadp-plugin can
# reach the hosted cluster API to pause/unpause the HostedCluster during backup.
NESTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
IMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
TOOLS_IMAGE=$(oc adm release info ${IMAGE} --image-for=tools)
oc create namespace oadp-helper
oc create secret generic oadp-kubeconfig-secret --from-file=kubeconfig="${NESTED_KUBECONFIG}" -n oadp-helper
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oadp-helper
  namespace: oadp-helper
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oadp-helper
  template:
    metadata:
      labels:
        app: oadp-helper
    spec:
      containers:
        - name: patch-container
          image: ${TOOLS_IMAGE}
          command: [ "sh", "-c", "while true; do sleep 3600; done" ]
          volumeMounts:
            - name: kubeconfig
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: kubeconfig
          secret:
            secretName: oadp-kubeconfig-secret
EOF

# Minio credentials (minio runs on the baremetal host)
cat <<EOF > /tmp/miniocred
[default]
aws_access_key_id=admin
aws_secret_access_key=admin123
EOF
oc create secret generic cloud-credentials -n openshift-adp --from-file cloud=/tmp/miniocred

# Create DataProtectionApplication with hypershift-oadp-plugin
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
          image: quay.io/hypershift/hypershift-oadp-plugin:latest
      noDefaultBackupLocation: true
      logLevel: debug
EOF

echo "Waiting for Velero pod to be ready..."
timeout 5m bash -c "until [[ \$(oc get deployment/velero -n openshift-adp -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null) == \"True\" ]]; do sleep 15; done"

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
    s3Url: "http://virthost.ostest.test.metalkube.org:9000"
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

echo "Waiting for BackupStorageLocation to become Available..."
oc wait --timeout=10m --all --for=jsonpath='{.status.phase}'=Available backupStorageLocation -n openshift-adp

echo "OADP setup complete. DPA, BSL (${CLUSTER_NAME}), and VSL are ready."
