#!/bin/bash

set -euxo pipefail

# Create namespace for the cluster
NAMESPACE="${HIVE_CLUSTER_NAME}"
oc create namespace "${NAMESPACE}"

# Get base domain from environment or SHARED_DIR
BASE_DOMAIN="${BASE_DOMAIN:-ibmcloud.qe.devcluster.openshift.com}"

# Create IBM Cloud credentials secret
# For Hive ClusterDeployment, we primarily need the API key
# Disable command echo to avoid exposing the API key in logs
set +x
IBMCLOUD_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"

oc create secret generic ibmcloud-credentials \
  --namespace="${NAMESPACE}" \
  --from-literal=ibmcloud_api_key="${IBMCLOUD_API_KEY}"
set -x

oc label secret ibmcloud-credentials \
  --namespace="${NAMESPACE}" \
  cluster.open-cluster-management.io/type=ibmcloud \
  cluster.open-cluster-management.io/credentials=""

# Create pull-secret
oc create secret generic pull-secret \
  --namespace="${NAMESPACE}" \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/pull-secret"

# Create SSH key secrets
oc create secret generic ssh-private-key \
  --namespace="${NAMESPACE}" \
  --type=Opaque \
  --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

oc create secret generic ssh-public-key \
  --namespace="${NAMESPACE}" \
  --type=Opaque \
  --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey"

# Create install-config
INSTALL_CONFIG_FILE="${SHARED_DIR}/hive-install-config.yaml"
cat > "${INSTALL_CONFIG_FILE}" <<EOF
apiVersion: v1
metadata:
  name: ${HIVE_CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
credentialsMode: Manual
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
  platform:
    ibmcloud:
      type: bx2-4x16
compute:
- hyperthreading: Enabled
  architecture: amd64
  name: worker
  replicas: 3
  platform:
    ibmcloud:
      type: bx2-4x16
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  ibmcloud:
    region: ${HIVE_IBM_REGION}
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

# Create install-config secret
oc create secret generic install-config \
  --namespace="${NAMESPACE}" \
  --type=Opaque \
  --from-file=install-config.yaml="${INSTALL_CONFIG_FILE}"

# Create CCO manifests for IBM Cloud Manual credentials mode
# IBM Cloud requires manual credential manifests for all operators
echo "Generating CCO manifests for IBM Cloud operators..."
MANIFESTS_DIR="${SHARED_DIR}/ibmcloud-manifests"
mkdir -p "${MANIFESTS_DIR}"

# Disable command echo to avoid exposing the API key in manifest generation
set +x

# cloud-controller-manager credentials manifest
cat > "${MANIFESTS_DIR}/openshift-cloud-controller-manager-ibm-cloud-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cloud-controller-manager
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IBMCLOUD_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-csi-drivers credentials manifest
cat > "${MANIFESTS_DIR}/openshift-cluster-csi-drivers-ibm-cloud-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cluster-csi-drivers
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IBMCLOUD_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-image-registry-operator credentials manifest
cat > "${MANIFESTS_DIR}/openshift-image-registry-installer-cloud-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: installer-cloud-credentials
  namespace: openshift-image-registry
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IBMCLOUD_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-ingress-operator credentials manifest
cat > "${MANIFESTS_DIR}/openshift-ingress-operator-cloud-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-ingress-operator
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IBMCLOUD_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# machine-api credentials manifest
cat > "${MANIFESTS_DIR}/openshift-machine-api-ibmcloud-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibmcloud-credentials
  namespace: openshift-machine-api
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IBMCLOUD_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# Re-enable command echo
set -x

# Create manifests secret from all generated manifests
echo "Creating manifests secret..."
oc create secret generic ibmcloud-manifests \
  --namespace="${NAMESPACE}" \
  --from-file="${MANIFESTS_DIR}/"

echo "CCO manifests created successfully"

# Get the latest ClusterImageSet for the current release
CLUSTER_IMAGESET_NAME="$(
  oc get clusterimagesets.hive.openshift.io \
    -o jsonpath='{.items[*].metadata.name}' \
    | tr ' ' '\n' \
    | grep "^img4\." \
    | sort -V \
    | tail -n 1
)"

if [ -z "${CLUSTER_IMAGESET_NAME}" ]; then
  echo "ERROR: No ClusterImageSet found"
  exit 1
fi

echo "Using ClusterImageSet: ${CLUSTER_IMAGESET_NAME}"

OCP_RELEASE_IMAGE="$(
  oc get clusterimageset "${CLUSTER_IMAGESET_NAME}" \
    -o jsonpath='{.spec.releaseImage}'
)"

echo "OCP Release Image: ${OCP_RELEASE_IMAGE}"

# Create ClusterDeployment
CLUSTER_DEPLOYMENT_FILE="${SHARED_DIR}/clusterdeployment.yaml"
cat > "${CLUSTER_DEPLOYMENT_FILE}" <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${HIVE_CLUSTER_NAME}
  namespace: ${NAMESPACE}
  labels:
    cloud: 'IBMCloud'
    region: '${HIVE_IBM_REGION}'
    vendor: OpenShift
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: ${HIVE_CLUSTER_NAME}
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    ibmcloud:
      region: ${HIVE_IBM_REGION}
      credentialsSecretRef:
        name: ibmcloud-credentials
  pullSecretRef:
    name: pull-secret
  installAttemptsLimit: 1
  provisioning:
    installConfigSecretRef:
      name: install-config
    imageSetRef:
      name: ${CLUSTER_IMAGESET_NAME}
    manifestsSecretRef:
      name: ibmcloud-manifests
    sshPrivateKeySecretRef:
      name: ssh-private-key
EOF

echo "Creating ClusterDeployment..."
oc apply -f "${CLUSTER_DEPLOYMENT_FILE}"

# Save cluster name and namespace for cleanup
echo "${HIVE_CLUSTER_NAME}" > "${SHARED_DIR}/hive-cluster-name"
echo "${NAMESPACE}" > "${SHARED_DIR}/hive-cluster-namespace"

# Wait for cluster deployment to complete
echo "Waiting for ClusterDeployment to provision (timeout: 60m)..."
oc wait --for=condition=Provisioned \
  --timeout=60m \
  clusterdeployment/${HIVE_CLUSTER_NAME} \
  --namespace="${NAMESPACE}" || {
    echo "ClusterDeployment failed or timed out. Checking status..."
    oc get clusterdeployment/${HIVE_CLUSTER_NAME} -n "${NAMESPACE}" -o yaml
    exit 1
  }

echo "ClusterDeployment ${HIVE_CLUSTER_NAME} provisioned successfully!"
oc get clusterdeployment/${HIVE_CLUSTER_NAME} -n "${NAMESPACE}"
