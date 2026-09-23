#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Windows Machine Config Operator using OLM v1 (ClusterExtension)"

echo "Creating ImageDigestMirrorSet for WMCO..."
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: wmco-idms
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-rhel9-operator
    mirrors:
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-16
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-17
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-18
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-19
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-20
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-21
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-4-22
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-16
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-17
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-18
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-19
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-20
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-21
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-22
  - source: registry.stage.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-16
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-17
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-18
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-19
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-20
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-21
      - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-4-22
EOF

echo "ImageDigestMirrorSet created successfully"
oc get imagedigestmirrorset wmco-idms

echo "Creating ClusterCatalog for WMCO..."
cat <<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: ${CATALOG_NAME}
spec:
  source:
    type: Image
    image:
      ref: ${FBC_IMAGE}
      pollIntervalMinutes: 1
EOF

echo "Waiting up to 5 mins for ClusterCatalog to be ready..."
for i in {1..30}; do
  CATALOG_STATUS=$(oc get clustercatalog ${CATALOG_NAME} -o jsonpath='{.status.conditions[?(@.type=="Serving")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${CATALOG_STATUS}" == "True" ]]; then
    echo "ClusterCatalog is ready!"
    break
  fi
  echo "Attempt $i: ClusterCatalog status: ${CATALOG_STATUS}. Waiting 10s..."
  sleep 10
done

oc get clustercatalog ${CATALOG_NAME} -o yaml

if ! oc get ns "${WMCO_NAMESPACE}"; then
  echo "Creating namespace ${WMCO_NAMESPACE}..."
  oc create ns "${WMCO_NAMESPACE}"
fi

echo "Enabling cluster monitoring on namespace..."
oc label namespace "${WMCO_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite=true

echo "Setting pod security enforcement to privileged..."
oc label namespace "${WMCO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite=true

echo "Creating cloud-private-key secret..."
oc create secret generic cloud-private-key \
  -n "${WMCO_NAMESPACE}" \
  --from-file=private-key.pem="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
  --dry-run=client -o yaml | oc apply -f -

echo "Creating ServiceAccount..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: windows-machine-config-operator-installer
  namespace: ${WMCO_NAMESPACE}
EOF

# Step 6: Create ClusterRoleBinding for WMCO installer
echo "Creating ClusterRoleBinding for installer..."
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: windows-machine-config-operator-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: windows-machine-config-operator-installer
  namespace: ${WMCO_NAMESPACE}
EOF

echo "Creating ClusterExtension for WMCO..."
cat <<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: windows-machine-config-operator
  annotations:
    olm.operatorframework.io/watch-namespace: ${WMCO_NAMESPACE}
spec:
  namespace: ${WMCO_NAMESPACE}
  serviceAccount:
    name: windows-machine-config-operator-installer
  config:
    configType: Inline
    inline:
      watchNamespace: ${WMCO_NAMESPACE}
  source:
    sourceType: Catalog
    catalog:
      packageName: ${PACKAGE_NAME}
      name: ${CATALOG_NAME}
EOF

echo "Waiting up to 5 mins for ClusterExtension to be installed..."
for i in {1..30}; do
  STATUS=$(oc get clusterextension windows-machine-config-operator -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${STATUS}" == "True" ]]; then
    echo "ClusterExtension successfully installed!"
    break
  fi
  echo "Attempt $i: ClusterExtension installed: ${STATUS}. Waiting 10s... "
  sleep 10
done

echo "ClusterExtension status:"
oc get clusterextension windows-machine-config-operator -o yaml

echo "Waiting for WMCO deployment to be ready..."
oc wait --for=condition=Available --timeout=10m deployment/windows-machine-config-operator -n "${WMCO_NAMESPACE}" || {
  echo "WMCO deployment did not become ready in time."
  oc get deployment/windows-machine-config-operator -n "${WMCO_NAMESPACE}" -o yaml
  oc get pods -n "${WMCO_NAMESPACE}"
  exit 1
}

echo "Success!"

echo "Checking deployments in namespace ${WMCO_NAMESPACE}"
oc get deployment -n "${WMCO_NAMESPACE}"

echo "Checking pods in namespace ${WMCO_NAMESPACE}"
oc get pods -n "${WMCO_NAMESPACE}"

echo "Checking pods logs in namespace ${WMCO_NAMESPACE}:"
oc logs deployment/windows-machine-config-operator -n ${WMCO_NAMESPACE}
