#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: openshift-cluster-csi-drivers-
  namespace: openshift-cluster-csi-drivers
spec:
  namespaces:
  - ""
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: "stable"
  name: aws-efs-csi-driver-operator
  source: qe-app-registry
  sourceNamespace: openshift-marketplace
EOF

cat > "${SHARED_DIR}"/efs-sc.yaml <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: \${storageclassname}
provisioner: efs.csi.aws.com
mountOptions:
  - tls
parameters:
  provisioningMode: efs-ap
  fileSystemId: \${filesystemid}
  directoryPerms: "700"
  basePath: "/dynamic_provisioning"
EOF

oc -n openshift-cluster-csi-drivers wait sub/aws-efs-csi-driver-operator --for=condition=CatalogSourcesUnhealthy=False --timeout=3m
EFS_CSI_DRIVER_OPERATOR_CSV=$(oc -n openshift-cluster-csi-drivers get sub/aws-efs-csi-driver-operator -o=jsonpath='{.status.currentCSV}')
echo "EFS CSI Driver Operator CurrentCSV is: ${EFS_CSI_DRIVER_OPERATOR_CSV}"
oc -n openshift-cluster-csi-drivers wait csv/"${EFS_CSI_DRIVER_OPERATOR_CSV}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
