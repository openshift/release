#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra post-install ************"
source ${SHARED_DIR}/platform-conf.sh
source ${SHARED_DIR}/nutanix_context.sh

mkdir -p /logs/artifacts
export LOG_DIR_FILE='/logs/artifacts/post-install.log'

export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc project default

timeout=5m

echo "Patching infrastructure/cluster"
oc patch infrastructure/cluster --type=merge --patch-file=/dev/stdin <<-EOF
{
  "spec": {
    "platformSpec": {
      "nutanix": {
        "prismCentral": {
          "address": "${NUTANIX_ENDPOINT}",
          "port": ${NUTANIX_PORT}
        },
        "prismElements": [
          {
            "endpoint": {
              "address": "${PE_HOST}",
              "port": ${PE_PORT}
            },
            "name": "${NUTANIX_CLUSTER_NAME}"
          }
        ]
      },
      "type": "Nutanix"
    }
  }
}
EOF

echo "infrastructure/cluster created"

cat <<EOF | oc create -f -
apiVersion: v1
kind: Secret
metadata:
   name: nutanix-credentials
   namespace: openshift-machine-api
type: Opaque
stringData:
  credentials: |
    [{"type":"basic_auth","data":{"prismCentral":{"username":"${NUTANIX_USERNAME}","password":"${NUTANIX_PASSWORD}"},"prismElements":null}}]
EOF

echo "machine API credentials created"

# debug post secret for security reasons 
set -x

version=$(oc version | grep -oE 'Server Version: ([0-9]+\.[0-9]+)' | sed 's/Server Version: //')

# Do the following if OCP version is >=4.13
# Cloud Provider Config is needed for CCM, which was introduced with 4.13 for Nutanix
if [[ $(echo -e "4.13
$version" | sort -V | tail -n 1) == "$version" ]]; then
  echo "Found OCP version greater or equal to 4.13, creating cloud-provider-config ConfigMap"
  cat <<EOF | oc apply -f -
kind: ConfigMap
apiVersion: v1
metadata:
  name: cloud-provider-config
  namespace: openshift-config
data:
  config: |
    {
    	"prismCentral": {
    		"address": "${NUTANIX_ENDPOINT}",
    		"port":${NUTANIX_PORT},
    		"credentialRef": {
    			"kind": "Secret",
    			"name": "nutanix-credentials",
    			"namespace": "openshift-cloud-controller-manager"
    		}
    	},
    	"topologyDiscovery": {
    		"type": "Prism",
    		"topologyCategories": null
    	},
    	"enableCustomLabeling": true
    }
EOF
fi

# Create Operator Group
cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: openshift-cluster-csi-drivers-
  namespace: openshift-cluster-csi-drivers
spec:
  targetNamespaces:
  - openshift-cluster-csi-drivers
  upgradeStrategy: Default
EOF

if [[ -z "$(oc get packagemanifests | grep nutanix)" ]]; then
  echo "Can't find CSI operator version that meet the OCP version"
  cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: nutanix-csi-operator-beta
  namespace: openshift-marketplace
spec:
  displayName: Nutanix Beta
  publisher: Nutanix-dev
  sourceType: grpc
  image: quay.io/ntnx-csi/nutanix-csi-operator-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 5m
EOF
fi

counter=1
echo "Waiting PackageManifests"
until [[ $(oc get packagemanifests nutanixcsioperator 2> /dev/null) ]]
  do
    if [[ "${counter}" -eq 90 ]];
    then
      echo "ERROR: Nutanix Package Manifests nutanixcsioperator was not found."
      oc -n openshift-marketplace get catalogsources.operators.coreos.com -o json
      oc -n openshift-marketplace get pods
      oc get packagemanifests nutanixcsioperator -o json
      exit 1
      break 
    fi
    ((counter++)) && sleep 2
done
echo "GOT PackageManifests"

cat <<EOF | oc create -f -
apiVersion: v1
kind: Secret
metadata:
  name: ntnx-secret
  namespace: openshift-cluster-csi-drivers
stringData:
  # prism-element-ip:prism-port:admin:password
  key: ${PE_HOST}:${PE_PORT}:${NUTANIX_USERNAME}:${NUTANIX_PASSWORD}
EOF

source=$(oc get packagemanifests nutanixcsioperator -o jsonpath=\{.status.catalogSource\})
source_namespace=$(oc get packagemanifests nutanixcsioperator -o jsonpath=\{.status.catalogSourceNamespace\})

cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nutanixcsioperator
  namespace: openshift-cluster-csi-drivers
spec:
  installPlanApproval: Automatic
  name: nutanixcsioperator
  source: ${source}
  sourceNamespace: ${source_namespace}
EOF

namespace="openshift-cluster-csi-drivers"
subscription="nutanixcsioperator"
echo "Waiting for Subscription to be ready..."
oc --namespace="${namespace}" wait --for=jsonpath='{..status.state}'="AtLatestKnown"  \
  --timeout=${timeout}  "subscriptions.operators.coreos.com/${subscription}" -o json

csv=$(oc get subscriptions.operators.coreos.com/${subscription} --namespace=${namespace} -o jsonpath='{..status.installedCSV}')
echo "Waiting for CSV ${csv} installation"
oc wait "clusterserviceversions.operators.coreos.com/${csv}" --namespace=${namespace}  --for=jsonpath='{..status.phase}'=Succeeded --timeout=${timeout} -o json

# Create a NutanixCsiStorage resource to deploy your driver
cat <<EOF | oc create -f -
apiVersion: crd.nutanix.com/v1alpha1
kind: NutanixCsiStorage
metadata:
  name: nutanixcsistorage
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF

NUTANIX_STORAGE_CONTAINER=SelfServiceContainer

cat <<EOF | oc create -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: nutanix-volume
  annotations:
    storageclass.kubernetes.io/is-default-class: 'true'
provisioner: csi.nutanix.com
parameters:
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-cluster-csi-drivers
  csi.storage.k8s.io/provisioner-secret-name: ntnx-secret
  storageContainer: ${NUTANIX_STORAGE_CONTAINER}
  csi.storage.k8s.io/controller-expand-secret-name: ntnx-secret
  csi.storage.k8s.io/node-publish-secret-namespace: openshift-cluster-csi-drivers
  storageType: NutanixVolumes
  csi.storage.k8s.io/node-publish-secret-name: ntnx-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-cluster-csi-drivers
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF


echo "Wait for pods to be up"
oc wait --namespace=openshift-cluster-csi-drivers --all --for=condition=Ready pods  --timeout=5m -o json

nutanix_pvc_name="nutanix-volume-pvc"
cat <<EOF | oc create -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: "${nutanix_pvc_name}"
  namespace: openshift-cluster-csi-drivers
  annotations:
    volume.beta.kubernetes.io/storage-provisioner: csi.nutanix.com
    volume.kubernetes.io/storage-provisioner: csi.nutanix.com
  finalizers:
    - kubernetes.io/pvc-protection
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: nutanix-volume
  volumeMode: Filesystem
EOF


namespace="openshift-cluster-csi-drivers"
deployment="nutanix-csi-operator-controller-manager" 

echo "Waiting for (deployment) on namespace (${namespace}) with name (${deployment}) to be created..."
for i in {1..40}; do
    oc get deployments.apps "${deployment}" --namespace="${namespace}" |& grep -ivE "(no resources found|not found)" && break || sleep 10
done

if [ $i -eq 40 ]; then
  echo "ERROR: failed Waiting for (deployment) on namespace (${namespace}) with name (${deployment}) to be created..."
  exit 1
fi

REPLICAS=$(oc get deployments.apps --namespace="${namespace}" "${deployment}"  -o jsonpath='{..status.replicas}')
echo "Waiting for rplicas in ${deployment} on namespace (${namespace})..."
oc wait -n "${namespace}" --all --for=jsonpath='{..status.availableReplicas}'="${REPLICAS}"  "deployments.apps/${deployment}" --timeout=5m


echo "waiting for clusteroperators to be ready"
timeout=15m
if  [[ $(oc wait --timeout=${timeout} --all=true clusteroperator --for='condition=available=true') ]] &&
    [[ $(oc wait --timeout=${timeout} --all=true clusteroperator --for='condition=progressing=false') ]] &&
    [[ $(oc wait --timeout=${timeout} --all=true clusteroperator --for='condition=degraded=false') ]];
then
  echo "All clusteroperators are Ready"
  echo "done!"
else
  echo "error: failed waiting for cluster operator"
  # deubg
  oc get clusteroperator | tee ${LOG_DIR_FILE}
  oc get clusteroperator -o json | tee ${LOG_DIR_FILE}
  exit 1
fi


timeout=10m
echo "Waiting for PersistentVolumeClaim to be Bound..."
if [[ $(oc --namespace "openshift-cluster-csi-drivers" wait --for=jsonpath='{..status.phase}'=Bound  \
  --timeout=${timeout}  "persistentvolumeclaim/${nutanix_pvc_name}" -o json) ]]
then
  echo "Cleanup PersistentVolumeClaim  ${nutanix_pvc_name}"
  oc delete pvc -n openshift-cluster-csi-drivers ${nutanix_pvc_name}
else
  oc get pvc/"${nutanix_pvc_name}" -n openshift-cluster-csi-drivers -o json
  exit 1
fi
  
