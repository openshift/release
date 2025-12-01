#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -v

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Generate unique cluster name with timestamp
TIMESTAMP=$(date +%Y%m%d%H%M%S)
export NAME="kops-test-${TIMESTAMP}.${BASE_DOMAIN}"
echo $NAME > ${SHARED_DIR}/cloud_name

# Install awscli
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate
pip install awscliv2

# S3 bucket names (fixed names)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_STORE="s3://kops-state-${ACCOUNT_ID}"
OIDC_STORE="s3://kops-oidc-${ACCOUNT_ID}"

export KOPS_STATE_STORE="${STATE_STORE}"

echo "Creating cluster: ${NAME}"
echo "State store: ${STATE_STORE}"
echo "OIDC store: ${OIDC_STORE}"

# Create S3 buckets for kops state and OIDC (check if they exist first)
echo "Checking/creating S3 bucket for kops state store..."
if ! aws s3 ls "${STATE_STORE}" >/dev/null 2>&1; then
    echo "Creating state store bucket..."
    aws s3 mb "${STATE_STORE}" --region us-west-2
    aws s3api put-bucket-versioning --bucket "${STATE_STORE##s3://}" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "${STATE_STORE##s3://}" --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }]
    }'
else
    echo "State store bucket already exists"
fi

echo "Checking/creating S3 bucket for OIDC discovery..."
if ! aws s3 ls "${OIDC_STORE}" >/dev/null 2>&1; then
    echo "Creating OIDC store bucket..."
    aws s3 mb "${OIDC_STORE}" --region us-west-2
    aws s3api put-bucket-versioning --bucket "${OIDC_STORE##s3://}" --versioning-configuration Status=Enabled
    aws s3api put-bucket-ownership-controls --bucket "${OIDC_STORE##s3://}" --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]'
    aws s3api put-public-access-block --bucket "${OIDC_STORE##s3://}" --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
    aws s3api put-bucket-acl --bucket "${OIDC_STORE##s3://}" --acl public-read
else
    echo "OIDC store bucket already exists"
fi

# Download latest kops binary
echo "Downloading latest kops binary..."
curl -Lo kops "https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r '.tag_name')/kops-linux-amd64"
chmod +x kops

# Create cluster configuration
echo "Creating kops cluster configuration..."
./kops create cluster "${NAME}" \
  --cloud=aws \
  --zones=$REGION \
  --node-count=$NUM_NODES \
  --node-size=$FLAVOR \
  --control-plane-size=$FLAVOR \
  --control-plane-count=$NUM_NODES_CONTROL_PLANE \
  --discovery-store="${OIDC_STORE}/${NAME}/discovery" \
  --kubernetes-version=$VERSION \
  --networking=$CNI \
  --yes

# Wait for cluster to be ready
echo "Waiting for cluster to become ready..."
./kops validate cluster --wait 15m

# Verify cluster is working
echo "Verifying cluster..."
kubectl get nodes
kubectl get pods -A
ls ~/.kube/config

# Export the kubeconfig so next steps can reuse it
cp ~/.kube/config ${SHARED_DIR}/kubeconfig
