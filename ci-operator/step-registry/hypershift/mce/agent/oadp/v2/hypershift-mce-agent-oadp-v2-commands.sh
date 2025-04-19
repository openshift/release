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
          image: quay.io/hypershift/hypershift-oadp-plugin:latest
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
