#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
oc create namespace oadp-helper
IMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
TOOLS_IMAGE=$(oc adm release info ${IMAGE} --image-for=tools)
oc create secret generic oadp-kubeconfig-secret --from-file=kubeconfig="$KUBECONFIG" -n oadp-helper
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
  backupLocations:
    - velero:
        config:
          profile: default
          region: minio
          s3ForcePathStyle: 'true'
          s3Url: 'http://virthost.ostest.test.metalkube.org:9000'
          insecureSkipTLSVerify: "true"
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
        - csi
      customPlugins:
        - name: hypershift-oadp-plugin
          image: quay.io/redhat-user-workloads/crt-redhat-acm-tenant/hypershift-oadp-plugin-main:latest
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
  includedResources:
  - sa
  - role
  - rolebinding
  - pod
  - pvc
  - pv
  - bmh
  - configmap
  - infraenv
  - priorityclasses
  - pdb
  - agents
  - hostedcluster
  - nodepool
  - secrets
  - services
  - deployments
  - statefulsets
  - hostedcontrolplane
  - cluster
  - agentcluster
  - clusterdeployment
  - agentmachinetemplate
  - agentmachine
  - machinedeployment
  - machineset
  - machine
  - route
  excludedResources: []
  storageLocation: dpa-sample-1
  ttl: 2h0m0s
  snapshotMoveData: true
  datamover: "velero"
  defaultVolumesToFsBackup: false
  snapshotVolumes: true
EOF
oc wait --timeout=45m --for=jsonpath='{.status.phase}'=Completed backup/hc-clusters-hosted-backup -n openshift-adp

oc delete hostedcluster -n local-cluster "${CLUSTER_NAME}"

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: hc-clusters-hosted-restore
  namespace: openshift-adp
spec:
  includedNamespaces:
  - local-cluster
  - local-cluster-${CLUSTER_NAME}
  backupName: hc-clusters-hosted-backup
  restorePVs: true
  preserveNodePorts: true
  existingResourcePolicy: update
  excludedResources:
  - pod
  - nodes
  - events
  - events.events.k8s.io
  - backups.velero.io
  - restores.velero.io
  - resticrepositories.velero.io
EOF

oc wait --timeout=45m --for=jsonpath='{.status.phase}'=Completed restore/hc-clusters-hosted-restore -n openshift-adp
oc wait --timeout=30m --for=condition=Available --namespace=local-cluster hostedcluster/${CLUSTER_NAME}
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
echo "Wait HostedCluster ready..."
until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 1s
done
oc get pod -A > "${ARTIFACT_DIR}/hostedcluster pods"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc get backup -n openshift-adp hc-clusters-hosted-backup -o yaml > "${ARTIFACT_DIR}/backup.yaml"
oc get restore hc-clusters-hosted-restore -n openshift-adp  -o yaml > "${ARTIFACT_DIR}/restore.yaml"