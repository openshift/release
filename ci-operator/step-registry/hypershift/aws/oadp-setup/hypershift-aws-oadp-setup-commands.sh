#!/bin/bash

set -euo pipefail

if [[ -n "${HYPERSHIFT_CLUSTER_ROLE:-}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  if [[ ! -s "${KUBECONFIG}" ]]; then
    echo "Management cluster kubeconfig ${KUBECONFIG} is missing or empty" >&2
    exit 1
  fi
fi

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
REGION="${OADP_AWS_REGION:-us-east-1}"
if [[ "${OADP_S3_BUCKET_NAME:-}" == *'${PROW_JOB_ID}'* ]]; then
  : "${PROW_JOB_ID:?PROW_JOB_ID is required to resolve the OADP S3 bucket name}"
  OADP_S3_BUCKET_NAME="${OADP_S3_BUCKET_NAME//\$\{PROW_JOB_ID\}/${PROW_JOB_ID}}"
fi
BUCKET_NAME="${OADP_S3_BUCKET_NAME:-hypershift-oadp-${CLUSTER_NAME}}"
OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/konveyor/hypershift-oadp-plugin:latest}"
export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

echo "Setting up OADP prerequisites for backup/restore tests"
echo "Cluster: ${CLUSTER_NAME}, Region: ${REGION}, Bucket: ${BUCKET_NAME}"

# Create S3 bucket for OADP backups once. This step may run against multiple
# management clusters that share the same BackupStorageLocation bucket.
if HEAD_BUCKET_ERROR="$(aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>&1)"; then
  echo "S3 bucket ${BUCKET_NAME} already exists; reusing it"
elif [[ "${HEAD_BUCKET_ERROR}" == *"(404)"* || "${HEAD_BUCKET_ERROR}" == *"Not Found"* ]]; then
  echo "Creating S3 bucket ${BUCKET_NAME}..."
  aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
    ${REGION:+$([ "${REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${REGION}" || echo "")}
else
  echo "Failed to check whether S3 bucket ${BUCKET_NAME} exists:" >&2
  echo "${HEAD_BUCKET_ERROR}" >&2
  exit 1
fi

# Save bucket name for cleanup
echo "${BUCKET_NAME}" > "${SHARED_DIR}/oadp-bucket-name"

# Create the openshift-adp namespace if it doesn't exist
oc get namespace openshift-adp 2>/dev/null || oc create namespace openshift-adp

# Create image pull secret so Velero can pull CI-built plugin images
if [[ -f /etc/ci-pull-credentials/.dockerconfigjson ]]; then
  echo "Creating CI registry pull secret in openshift-adp namespace..."
  oc create secret docker-registry ci-pull-secret \
    --namespace openshift-adp \
    --from-file=.dockerconfigjson=/etc/ci-pull-credentials/.dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
  oc secrets link default ci-pull-secret --for=pull -n openshift-adp
  oc secrets link velero ci-pull-secret --for=pull -n openshift-adp 2>/dev/null || true
fi

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
          image: ${OADP_PLUGIN_IMAGE}
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

echo "OADP setup complete"
