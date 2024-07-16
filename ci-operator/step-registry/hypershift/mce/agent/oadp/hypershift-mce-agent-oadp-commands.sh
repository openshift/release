#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

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
  backupLocations:
    - velero:
        config:
          profile: default
          region: minio
          s3ForcePathStyle: 'true'
          s3Url: 'http://virthost.ostest.test.metalkube.org:9000'
        credential:
          key: cloud
          name: cloud-credentials
        default: true
        objectStorage:
          bucket: oadp-backup
          prefix: hcp
        provider: aws
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      defaultPlugins:
        - openshift
        - aws
        - kubevirt
  snapshotLocations:
    - velero:
        config:
          profile: default
          region: minio
        provider: aws
EOF

oc wait --timeout=20m --for=condition=Reconciled DataProtectionApplication/dpa-sample -n openshift-adp
oc wait --timeout=20m --all --for=jsonpath='{.status.phase}'=Available backupStorageLocation -n openshift-adp

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
oc scale nodepool ${CLUSTER_NAME} -n local-cluster --replicas 0
oc patch nodepool -n local-cluster ${CLUSTER_NAME}  --type json -p '[{"op": "add", "path": "/spec/pausedUntil", "value": "true"}]'
oc patch hostedcluster -n local-cluster ${CLUSTER_NAME}  --type json -p '[{"op": "add", "path": "/spec/pausedUntil", "value": "true"}]'
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: hc-clusters-hosted-backup
  namespace: openshift-adp
  labels:
    velero.io/storage-location: default
spec:
  hooks: {}
  includedNamespaces:
  - local-cluster
  - local-cluster-${CLUSTER_NAME}
  includedResources: []
  excludedResources: []
  storageLocation: dpa-sample-1
  ttl: 2h0m0s
  snapshotMoveData: true
  datamover: "velero"
  defaultVolumesToFsBackup: true
EOF
oc wait --timeout=45m --for=jsonpath='{.status.phase}'=Completed backup/hc-clusters-hosted-backup -n openshift-adp

oc patch hostedcluster -n local-cluster ${CLUSTER_NAME}  --type json -p '[{"op": "add", "path": "/spec/pausedUntil", "value": "false"}]'
oc patch nodepool -n local-cluster ${CLUSTER_NAME}  --type json -p '[{"op": "add", "path": "/spec/pausedUntil", "value": "false"}]'
#oc delete hostedcluster/${CLUSTER_NAME} -n local-cluster
##
#cat <<EOF | oc apply -f -
#apiVersion: velero.io/v1
#kind: Restore
#metadata:
#  name: hc-clusters-hosted-restore
#  namespace: openshift-adp
#spec:
#  includedNamespaces:
#  - local-cluster
#  - local-cluster-b4e09e601e3e26d055cd
#  backupName: hc-clusters-hosted-backup
#  restorePVs: true
#  preserveNodePorts: true
#  existingResourcePolicy: update
#  excludedResources:
#  - nodes
#  - events
#  - events.events.k8s.io
#  - backups.velero.io
#  - restores.velero.io
#  - resticrepositories.velero.io
#EOF
#
#oc wait --timeout=45m --for=jsonpath='{.status.phase}'=Completed restore/hc-clusters-hosted-restore -n openshift-adp
#oc get backup -n openshift-adp hc-clusters-hosted-backup -o yaml > "${ARTIFACT_DIR}/backup.yaml"
#oc get restore hc-clusters-hosted-restore -n openshift-adp  -o yaml > "${ARTIFACT_DIR}/restore.yaml"