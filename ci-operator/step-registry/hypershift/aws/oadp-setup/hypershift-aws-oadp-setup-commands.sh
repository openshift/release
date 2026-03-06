#!/bin/bash

set -euo pipefail

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
REGION="${OADP_AWS_REGION:-us-east-1}"
BUCKET_NAME="${OADP_S3_BUCKET_NAME:-hypershift-oadp-${CLUSTER_NAME}}"
export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

echo "Setting up OADP prerequisites for backup/restore tests"
echo "Cluster: ${CLUSTER_NAME}, Region: ${REGION}, Bucket: ${BUCKET_NAME}"

# Create S3 bucket for OADP backups
echo "Creating S3 bucket ${BUCKET_NAME}..."
aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
  ${REGION:+$([ "${REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${REGION}" || echo "")}

# Save bucket name for cleanup
echo "${BUCKET_NAME}" > "${SHARED_DIR}/oadp-bucket-name"

# Create the openshift-adp namespace if it doesn't exist
oc get namespace openshift-adp 2>/dev/null || oc create namespace openshift-adp

# Create secret with AWS credentials
echo "Creating AWS credentials secret..."
# Disable tracing due to credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

SECRET_DATA="$(base64 -w 0 "${AWS_SHARED_CREDENTIALS_FILE}")"

cat <<EOF | oc apply -f -
apiVersion: v1
data:
  credentials: ${SECRET_DATA}
kind: Secret
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
type: Opaque
EOF

$WAS_TRACING && set -x

# Create DataProtectionApplication
echo "Creating DataProtectionApplication..."
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-instance
  namespace: openshift-adp
spec:
  backupImages: false
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      customPlugins:
        - name: hypershift-oadp-plugin
          image: quay.io/redhat-user-workloads/ocp-art-tenant/oadp-hypershift-oadp-plugin-main:main
      defaultPlugins:
        - openshift
        - aws
        - csi
        - kubevirt
      disableFsBackup: false
      resourceTimeout: 2h
      noDefaultBackupLocation: true
      logLevel: debug
EOF

# Wait for Velero pod to be ready
echo "Waiting for Velero pod to be ready..."
oc wait --for=condition=Available deployment/velero -n openshift-adp --timeout=300s || true

# Create BackupStorageLocation
echo "Creating BackupStorageLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: aws
  objectStorage:
    bucket: ${BUCKET_NAME}
    prefix: backup-objects
  credential:
    name: ${CLUSTER_NAME}
    key: credentials
  config:
    region: ${REGION}
    profile: default
EOF

# Create VolumeSnapshotLocation
echo "Creating VolumeSnapshotLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: VolumeSnapshotLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: aws
  credential:
    name: ${CLUSTER_NAME}
    key: credentials
  config:
    region: ${REGION}
    profile: default
EOF

echo "OADP setup complete"
