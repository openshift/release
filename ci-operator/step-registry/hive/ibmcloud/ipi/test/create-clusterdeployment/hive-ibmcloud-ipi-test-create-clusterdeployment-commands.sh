#!/bin/bash

set -euo pipefail

echo "[INFO] Creating ClusterDeployment for spoke cluster"
echo "[INFO] Reference: https://github.com/openshift/hive/blob/master/docs/using-hive.md#ibm-cloud"

# Read configuration from SHARED_DIR
SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke-cluster-name)"
IMAGESET_NAME="$(cat ${SHARED_DIR}/spoke-clusterimageset-name)"
SPOKE_REGION="$(cat ${SHARED_DIR}/spoke-region)"
SPOKE_BASE_DOMAIN="${SPOKE_BASE_DOMAIN:-ci-ibmcloud.devcluster.openshift.com}"

echo "[INFO] Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "[INFO] ClusterImageSet: ${IMAGESET_NAME}"
echo "[INFO] Region: ${SPOKE_REGION}"
echo "[INFO] Base domain: ${SPOKE_BASE_DOMAIN}"

# Create ClusterDeployment following Hive documentation pattern
echo "[INFO] Creating ClusterDeployment resource"
oc apply -f - <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${SPOKE_CLUSTER_NAME}
  namespace: ${SPOKE_CLUSTER_NAME}
  labels:
    cloud: IBMCloud
    region: ${SPOKE_REGION}
    vendor: OpenShift
spec:
  baseDomain: ${SPOKE_BASE_DOMAIN}
  clusterName: ${SPOKE_CLUSTER_NAME}
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    ibmcloud:
      region: ${SPOKE_REGION}
      credentialsSecretRef:
        name: ibmcloud-credentials
  pullSecretRef:
    name: pull-secret
  installAttemptsLimit: 1
  provisioning:
    installConfigSecretRef:
      name: install-config
    imageSetRef:
      name: ${IMAGESET_NAME}
    sshPrivateKeySecretRef:
      name: ssh-private-key
    manifestsConfigMapRefs:
    - name: ibmcloud-manual-creds-manifests
EOF

echo "[SUCCESS] ClusterDeployment ${SPOKE_CLUSTER_NAME} created"

# Display the ClusterDeployment
echo "[INFO] ClusterDeployment details:"
oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" -o yaml

# Wait for Hive to process the ClusterDeployment
echo "[INFO] Waiting for Hive to process the ClusterDeployment..."
sleep 10

# Check if provision job has been created by Hive
echo "[INFO] Checking for Hive provision job creation"
for i in {1..30}; do
  INSTALL_JOBS=$(oc -n "${SPOKE_CLUSTER_NAME}" get jobs \
    -l "hive.openshift.io/cluster-deployment-name=${SPOKE_CLUSTER_NAME},hive.openshift.io/job-type=provision" \
    --no-headers 2>/dev/null | wc -l)

  if [ "${INSTALL_JOBS}" -gt 0 ]; then
    echo "[SUCCESS] Hive provision job created"
    oc -n "${SPOKE_CLUSTER_NAME}" get jobs \
      -l "hive.openshift.io/cluster-deployment-name=${SPOKE_CLUSTER_NAME}"
    break
  fi

  if [ $i -eq 30 ]; then
    echo "[WARN] Provision job not yet created, but continuing"
  fi

  echo "[INFO] Waiting for Hive to create provision job... ($i/30)"
  sleep 5
done

# Display ClusterDeployment status
echo "[INFO] ClusterDeployment status:"
oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.status}' | jq '.' 2>/dev/null || \
  oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.status}'

echo ""
echo "[INFO] ClusterDeployment created successfully"
echo "[INFO] Hive will now provision the spoke cluster on IBM Cloud"
echo "[INFO] This process typically takes 45-60 minutes"
