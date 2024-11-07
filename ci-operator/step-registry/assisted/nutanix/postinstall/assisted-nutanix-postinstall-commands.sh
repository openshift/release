#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra post-install ************"
source ${SHARED_DIR}/platform-conf.sh
source ${SHARED_DIR}/nutanix_context.sh

export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc project default

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

version=$(oc version | grep -oE 'Server Version: ([0-9]+\.[0-9]+)' | sed 's/Server Version: //')
resource_timeout_seconds=300

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
  cat <<EOF | oc apply -f -
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

  start_time=$(date +%s)
  while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    if [[ $(oc get catalogsource nutanix-csi-operator-beta -n openshift-marketplace -o 'jsonpath={..status.connectionState.lastObservedState}') == "READY" ]]; then
      echo "CatalogSource is now READY."
      if oc get packagemanifests nutanixcsioperator &> /dev/null; then
        echo "Package Manifests nutanixcsioperator is now READY."
        break
      fi
      echo "Waiting for nutanixcsioperator package manifests to become READY ..."
    fi

    if [[ ${elapsed_time} -ge ${resource_timeout_seconds} ]]; then
      echo "Timeout: Nutanix CSI CatalogSource did not become READY within ${resource_timeout_seconds} seconds."
      exit 1
    fi

    echo "Waiting for CatalogSource to be READY..."
    sleep 5s
  done
fi


starting_csv=$(oc get packagemanifests nutanixcsioperator -o jsonpath=\{.status.channels[*].currentCSV\})
source=$(oc get packagemanifests nutanixcsioperator -o jsonpath=\{.status.catalogSource\})
source_namespace=$(oc get packagemanifests nutanixcsioperator -o jsonpath=\{.status.catalogSourceNamespace\})

cat <<EOF | oc apply -f -
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
  startingCSV: ${starting_csv}
EOF

start_time=$(date +%s)
while true; do
  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))

  if [[ $(oc get subscription nutanixcsioperator -n openshift-cluster-csi-drivers -o 'jsonpath={..status.state}') == "AtLatestKnown" ]]; then
    echo "Subscription is now ready."
    break
  fi

  if [[ ${elapsed_time} -ge ${resource_timeout_seconds} ]]; then
    echo "Timeout: Nutanix operator subscription did not become ready within ${resource_timeout_seconds} seconds."
    exit 1
  fi

  echo "Waiting for Subscription to be ready..."
  sleep 5
done

# Create a NutanixCsiStorage resource to deploy your driver
cat <<EOF | oc create -f -
apiVersion: crd.nutanix.com/v1alpha1
kind: NutanixCsiStorage
metadata:
  name: nutanixcsistorage
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF

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

start_time=$(date +%s)
while true; do
  if oc get pvc/"${nutanix_pvc_name}" -n openshift-cluster-csi-drivers &>/dev/null; then
    pvc_status=$(oc get pvc/"${nutanix_pvc_name}" -n openshift-cluster-csi-drivers -o 'jsonpath={..status.phase}')
    if [[ "$pvc_status" == "Bound" ]]; then
      echo "PersistentVolumeClaim is now Bound."
      break
    fi
  fi

  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))

  if [[ ${elapsed_time} -ge ${resource_timeout_seconds} ]]; then
    echo "Timeout: PersistentVolumeClaim did not become Bound within ${resource_timeout_seconds} seconds."
    exit 1
  fi

  echo "Waiting for PersistentVolumeClaim to be Bound..."
  sleep 5
done

oc delete pvc -n openshift-cluster-csi-drivers ${nutanix_pvc_name}

until
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null &&
    oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null &&
    oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null
do
  echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
  sleep 1s
done
