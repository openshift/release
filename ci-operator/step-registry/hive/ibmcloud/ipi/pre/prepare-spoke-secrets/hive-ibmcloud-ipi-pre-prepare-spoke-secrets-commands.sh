#!/bin/bash

set -euo pipefail

echo "[INFO] Preparing secrets for spoke cluster deployment"
echo "[INFO] Following Hive documentation: https://github.com/openshift/hive/blob/master/docs/using-hive.md#ibm-cloud"

# Generate unique spoke cluster name
SPOKE_CLUSTER_NAME="hive-spoke-$(printf "%s" "${PROW_JOB_ID:-$(date +%s)}" | sha256sum | cut -c1-10)"
echo "[INFO] Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "${SPOKE_CLUSTER_NAME}" > "${SHARED_DIR}/spoke-cluster-name"

# Create namespace for spoke cluster
echo "[INFO] Creating namespace: ${SPOKE_CLUSTER_NAME}"
oc create namespace "${SPOKE_CLUSTER_NAME}"

# Determine spoke cluster region
# Use LEASED_RESOURCE if available, otherwise default region
SPOKE_REGION="${LEASED_RESOURCE:-us-east}"
echo "[INFO] Spoke cluster region: ${SPOKE_REGION}"
echo "${SPOKE_REGION}" > "${SHARED_DIR}/spoke-region"

# Spoke base domain
SPOKE_BASE_DOMAIN="${SPOKE_BASE_DOMAIN:-ci-ibmcloud.devcluster.openshift.com}"
echo "[INFO] Spoke base domain: ${SPOKE_BASE_DOMAIN}"

# Read IBM Cloud API key
IBMCLOUD_API_KEY=$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")

# Step 1: Create IBM Cloud credentials secret
# Reference: https://github.com/openshift/hive/blob/master/docs/using-hive.md#pull-secret
# Under "Create a secret containing your IBM Cloud API key:"
echo "[INFO] Creating IBM Cloud credentials secret (following Hive docs pattern)"
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibmcloud-credentials
  namespace: ${SPOKE_CLUSTER_NAME}
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF

echo "[INFO] IBM Cloud credentials secret created"

# Step 2: Create pull-secret
# Reference: https://github.com/openshift/hive/blob/master/docs/using-hive.md#pull-secret
echo "[INFO] Creating pull-secret"
oc -n "${SPOKE_CLUSTER_NAME}" create secret generic pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/pull-secret"

# Step 3: Create SSH private key secret
echo "[INFO] Creating SSH key secret"
oc -n "${SPOKE_CLUSTER_NAME}" create secret generic ssh-private-key \
  --type=Opaque \
  --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

# Read SSH public key
SSH_PUBLIC_KEY=$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")

# Step 4: Generate install-config.yaml for spoke cluster
echo "[INFO] Generating install-config.yaml for spoke cluster"
cat > /tmp/spoke-install-config.yaml <<EOF
apiVersion: v1
metadata:
  name: ${SPOKE_CLUSTER_NAME}
baseDomain: ${SPOKE_BASE_DOMAIN}
credentialsMode: Manual
platform:
  ibmcloud:
    region: ${SPOKE_REGION}
controlPlane:
  name: master
  replicas: 3
  platform:
    ibmcloud:
      type: bx2-4x16
      zones:
      - ${SPOKE_REGION}-1
      - ${SPOKE_REGION}-2
      - ${SPOKE_REGION}-3
compute:
- name: worker
  replicas: ${SPOKE_WORKERS:-2}
  platform:
    ibmcloud:
      type: bx2-4x16
      zones:
      - ${SPOKE_REGION}-1
      - ${SPOKE_REGION}-2
      - ${SPOKE_REGION}-3
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
sshKey: |
  ${SSH_PUBLIC_KEY}
pullSecret: |
  $(cat "${CLUSTER_PROFILE_DIR}/pull-secret")
EOF

# Create install-config secret
echo "[INFO] Creating install-config secret"
oc -n "${SPOKE_CLUSTER_NAME}" create secret generic install-config \
  --from-file=install-config.yaml=/tmp/spoke-install-config.yaml

# Save install-config for reference
cp /tmp/spoke-install-config.yaml "${SHARED_DIR}/spoke-install-config.yaml"

# Step 5: Generate IBM Cloud credential manifests for manual mode
# Reference: https://github.com/openshift/hive/blob/master/docs/using-hive.md#ibm-cloud-credential-manifests
echo "[INFO] Generating IBM Cloud credential manifests for manual credentials mode"
mkdir -p /tmp/spoke-manifests

# Create the credential manifest that will be injected into the spoke cluster
# This secret will be created in the kube-system namespace of the spoke cluster
cat > /tmp/spoke-manifests/ibmcloud-credentials.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibmcloud-credentials
  namespace: kube-system
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF

echo "[INFO] IBM Cloud credential manifest created"

# Create ConfigMap containing the manifests
# Hive will inject these manifests into the spoke cluster during installation
echo "[INFO] Creating manifests ConfigMap"
oc -n "${SPOKE_CLUSTER_NAME}" create configmap ibmcloud-manual-creds-manifests \
  --from-file=/tmp/spoke-manifests/

echo "[SUCCESS] Spoke cluster secrets and manifests prepared successfully"
echo ""
echo "=========================================="
echo "Spoke Cluster Configuration Summary"
echo "=========================================="
echo "Cluster Name: ${SPOKE_CLUSTER_NAME}"
echo "Namespace: ${SPOKE_CLUSTER_NAME}"
echo "Region: ${SPOKE_REGION}"
echo "Base Domain: ${SPOKE_BASE_DOMAIN}"
echo "Control Plane Replicas: 3"
echo "Worker Replicas: ${SPOKE_WORKERS:-2}"
echo "Credentials Mode: Manual"
echo ""
echo "Secrets Created:"
echo "  - ibmcloud-credentials (IBM Cloud API key)"
echo "  - pull-secret (Container registry pull secret)"
echo "  - ssh-private-key (SSH key for node access)"
echo "  - install-config (Install configuration)"
echo ""
echo "ConfigMaps Created:"
echo "  - ibmcloud-manual-creds-manifests (Manual credentials for spoke cluster)"
echo "=========================================="
