#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creating Hive ClusterDeployment for IBM Cloud"

# Generate unique spoke cluster name
SPOKE_CLUSTER_NAME="hive-ibm-${PULL_NUMBER:-0}-$(date +%s | cut -c 6-10)"
SPOKE_NAMESPACE="${SPOKE_CLUSTER_NAME}"
REGION="${LEASED_RESOURCE}"

echo "Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "Spoke namespace: ${SPOKE_NAMESPACE}"
echo "Region: ${REGION}"

# Save to SHARED_DIR for other steps
echo "${SPOKE_CLUSTER_NAME}" > "${SHARED_DIR}/hive-spoke-cluster-name"
echo "${SPOKE_NAMESPACE}" > "${SHARED_DIR}/hive-spoke-namespace"

# Create namespace for spoke cluster
echo "Creating namespace ${SPOKE_NAMESPACE}..."
oc create namespace "${SPOKE_NAMESPACE}"

# Create pull secret
echo "Creating pull secret..."
oc create secret generic pull-secret \
  -n "${SPOKE_NAMESPACE}" \
  --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/pull-secret" \
  --type=kubernetes.io/dockerconfigjson

# Create IBM Cloud credentials secret
echo "Creating IBM Cloud credentials secret..."
IBMCLOUD_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
oc create secret generic ibmcloud-credentials \
  -n "${SPOKE_NAMESPACE}" \
  --from-literal=ibmcloud_api_key="${IBMCLOUD_API_KEY}"

# Create install-config secret
echo "Creating install-config secret..."
if [ ! -f "${SHARED_DIR}/install-config.yaml" ]; then
  echo "ERROR: install-config.yaml not found in SHARED_DIR"
  echo "The ipi-conf-ibmcloud chain should have generated this file"
  exit 1
fi
oc create secret generic install-config \
  -n "${SPOKE_NAMESPACE}" \
  --from-file=install-config.yaml="${SHARED_DIR}/install-config.yaml"

# Create CCO manifests secret
echo "Creating CCO manifests secret..."
# Verify all 5 CCO manifest files exist
CCO_MANIFESTS=(
  "manifest_openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml"
  "manifest_openshift-cluster-csi-drivers-ibm-cloud-credentials-credentials.yaml"
  "manifest_openshift-image-registry-installer-cloud-credentials-credentials.yaml"
  "manifest_openshift-ingress-operator-cloud-credentials-credentials.yaml"
  "manifest_openshift-machine-api-ibmcloud-credentials-credentials.yaml"
)

for manifest in "${CCO_MANIFESTS[@]}"; do
  if [ ! -f "${SHARED_DIR}/${manifest}" ]; then
    echo "ERROR: ${manifest} not found in SHARED_DIR"
    echo "The ipi-conf-ibmcloud-manual-creds step should have generated this file"
    exit 1
  fi
done

# Create secret with all CCO manifests
oc create secret generic cco-manifests \
  -n "${SPOKE_NAMESPACE}" \
  --from-file="${SHARED_DIR}/manifest_openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml" \
  --from-file="${SHARED_DIR}/manifest_openshift-cluster-csi-drivers-ibm-cloud-credentials-credentials.yaml" \
  --from-file="${SHARED_DIR}/manifest_openshift-image-registry-installer-cloud-credentials-credentials.yaml" \
  --from-file="${SHARED_DIR}/manifest_openshift-ingress-operator-cloud-credentials-credentials.yaml" \
  --from-file="${SHARED_DIR}/manifest_openshift-machine-api-ibmcloud-credentials-credentials.yaml"

# Create ClusterImageSet
echo "Creating ClusterImageSet..."
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ${SPOKE_CLUSTER_NAME}-imageset
spec:
  releaseImage: ${RELEASE_IMAGE_LATEST}
EOF

# Create ClusterDeployment
echo "Creating ClusterDeployment..."
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${SPOKE_CLUSTER_NAME}
  namespace: ${SPOKE_NAMESPACE}
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: ${SPOKE_CLUSTER_NAME}
  platform:
    ibmcloud:
      credentialsSecretRef:
        name: ibmcloud-credentials
      region: ${REGION}
  provisioning:
    installConfigSecretRef:
      name: install-config
    imageSetRef:
      name: ${SPOKE_CLUSTER_NAME}-imageset
    manifestsSecretRef:
      name: cco-manifests
  pullSecretRef:
    name: pull-secret
EOF

echo "ClusterDeployment created successfully"
echo "Cluster: ${SPOKE_CLUSTER_NAME}"
echo "Namespace: ${SPOKE_NAMESPACE}"
echo "Region: ${REGION}"

# Display ClusterDeployment status
oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" -o yaml
