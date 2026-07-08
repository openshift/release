#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'rm -f /tmp/ps-orig.json /tmp/ps-merged.json /tmp/icsp.yaml' EXIT

ODF_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-stable-${ODF_VERSION_MAJOR_MINOR}}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-odf-operator}"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-gp2-csi}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-50}Gi"
ODF_STORAGE_CLUSTER_NAME="${ODF_STORAGE_CLUSTER_NAME:-ocs-storagecluster}"
ODF_DEFAULT_SC="${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd"

CATALOG_IMAGE="${ODF_CATALOG_IMAGE:-quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}}"
CATALOG_NAME=odf-catalogsource
CREDS_FILE=/tmp/secrets/odf-quay-credentials/rhceph-dev

if [[ ! -f "${CREDS_FILE}" ]]; then
  echo "ERROR: ODF Quay credentials not found at ${CREDS_FILE}"
  exit 1
fi

echo "Merging ODF Quay credentials into cluster pull secret"
oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > /tmp/ps-orig.json
jq '. * input' /tmp/ps-orig.json "${CREDS_FILE}" > /tmp/ps-merged.json
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/ps-merged.json

pushd /tmp

echo "Installing ODF from ${ODF_OPERATOR_CHANNEL} into ${ODF_INSTALL_NAMESPACE}"

echo "Creating namespace ${ODF_INSTALL_NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_INSTALL_NAMESPACE}"
EOF

echo "Creating OperatorGroup"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${ODF_INSTALL_NAMESPACE}-operator-group"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - "${ODF_INSTALL_NAMESPACE}"
EOF

echo "Extracting ICSP from catalog image"
oc image extract "${CATALOG_IMAGE}" --file /icsp.yaml || true
if [[ -f icsp.yaml ]]; then
  echo "Applying ICSP"
  oc apply --filename=icsp.yaml
  sleep 30
  echo "Waiting for MCP rollout"
  for i in $(seq 1 60); do
    echo "MCP wait attempt ${i}/60"
    if oc wait mcp --all --for condition=updated --timeout=1m; then
      echo "MCP is Updated"
      break
    fi
    sleep 30
    if [[ $i -eq 60 ]]; then
      echo "ERROR: MCP did not stabilize"
      exit 1
    fi
  done
fi

echo "Creating CatalogSource (image: ${CATALOG_IMAGE})"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  displayName: ODF Dev Catalog
  image: ${CATALOG_IMAGE}
  publisher: Red Hat
  sourceType: grpc
EOF

echo "Waiting for CatalogSource to be ready"
sleep 30
oc wait "catalogSource/${CATALOG_NAME}" -n openshift-marketplace \
  --for=jsonpath='{.status.connectionState.lastObservedState}=READY' --timeout=5m

echo "Creating Subscription"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${ODF_SUBSCRIPTION_NAME}
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  channel: ${ODF_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: ${ODF_SUBSCRIPTION_NAME}
  source: ${CATALOG_NAME}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for CSV"
CSV_READY=false
for i in $(seq 1 60); do
  CSV=$(oc -n "${ODF_INSTALL_NAMESPACE}" get subscription "${ODF_SUBSCRIPTION_NAME}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc -n "${ODF_INSTALL_NAMESPACE}" get csv "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "CSV ${CSV} is ready"
      CSV_READY=true
      break
    fi
  fi
  sleep 10
done

if [[ "${CSV_READY}" != "true" ]]; then
  echo "ERROR: CSV did not reach Succeeded phase after 10 minutes (current: ${PHASE:-not found})"
  exit 1
fi

echo "Waiting for ocs-operator deployment"
sleep 90
oc wait deployment ocs-operator -n "${ODF_INSTALL_NAMESPACE}" \
  --for=condition=Available --timeout=5m

echo "Labeling worker nodes for ODF"
oc label --overwrite nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker'

echo "Creating StorageCluster"
oc apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ${ODF_STORAGE_CLUSTER_NAME}
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: ${ODF_VOLUME_SIZE}
        storageClassName: ${ODF_BACKEND_STORAGE_CLASS}
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

echo "Waiting for StorageCluster to be available"
oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
  -n "${ODF_INSTALL_NAMESPACE}" --for=condition=Available --timeout=120m

echo "Setting ${ODF_DEFAULT_SC} as default storage class"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
oc annotate storageclass "${ODF_DEFAULT_SC}" storageclass.kubernetes.io/is-default-class=true

popd
echo "ODF deployed successfully"
