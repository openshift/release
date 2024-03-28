#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

#label the nodes
nodes=$(oc get nodes -o name)
for nodeName in ${nodes}
do
  node=$(basename "${nodeName}")
  oc label nodes ${node} cluster.ocs.openshift.io/openshift-storage='' --overwrite
done

#Disable the default resource
oc patch operatorhub.config.openshift.io/cluster -p='{"spec":{"sources":[{"disabled":true,"name":"redhat-operators"}]}}' --type=merge

echo "Extract ICSP from the catalog image"
oc image extract "quay.io/rhceph-dev/ocs-registry:latest-${ODF_CHANNEL}" --file /icsp.yaml || true
# Create an ICSP if applicable
if [ -e "icsp.yaml" ] ; then
  echo "Create an ICSP if applicable"
  oc apply --filename="icsp.yaml"
  sleep 30
fi

echo "Create CatalogSource"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
  labels:
    ocs-operator-internal: "true"
spec:
  displayName: Openshift Container Storage
  icon:
    base64data: ""
    mediatype: ""
  image: "quay.io/rhceph-dev/ocs-registry:latest-${ODF_CHANNEL}"
  publisher: Red Hat
  sourceType: grpc
  priority: 100
  # If the registry image still have the same tag (latest-stable-4.6, or for stage testing)
  # we need to have this updateStrategy, otherwise we will not see new pushed content.
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

oc -n openshift-marketplace get CatalogSource redhat-operators || true

echo "Create namespace and operator group"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-storage
spec: {}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  creationTimestamp: null
  targetNamespaces:
    - openshift-storage
EOF

echo "Create subscription"
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: "${ODF_CHANNEL}"
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Verify CSV status"
sleep 10
csvs=$(oc get csv -o name -n openshift-storage)
for csv in ${csvs}
do
  oc wait --for=jsonpath='{.status.phase}'=Succeeded -n openshift-storage --timeout=600s ${csv}
done

echo "Wait for OCS Operator deployment to be ready"
oc wait deployment ocs-operator \
  --namespace=openshift-storage \
  --for=condition='Available' \
  --timeout='600s'

oc -n openshift-storage get pods || true
oc get crd storagesystems.odf.openshift.io || true

echo "Apply storage system"
cat <<EOF | oc apply -f -
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: openshift-storage
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: openshift-storage
EOF

sleep 10

echo "Create Storage Cluster"
cat <<EOF | oc create -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 256Gi
        storageClassName: gp2-csi
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources:
      Limits: null
      Requests: null
EOF

sleep 30
echo "Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n openshift-storage --for=condition='Available' --timeout='10m'

echo "ODF/OCS Operator is deployed successfully"


