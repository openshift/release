#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${UNIQUE_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# extract aws credentials requests from the release image
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

oc registry login
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST"

# Create extra efs csi driver iam resources, it's optional only for efs csi driver related tests on sts clusters
if [[ "${CREATE_EFS_CSI_DRIVER_IAM}" == "yes" ]]; then
  cat <<EOF >/tmp/credrequests/aws-efs-csi-driver-operator-credentialsrequest.yaml
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  name: openshift-aws-efs-csi-driver
  namespace: openshift-cloud-credential-operator
spec:
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: AWSProviderSpec
    statementEntries:
    - action:
      - elasticfilesystem:*
      effect: Allow
      resource: '*'
  secretRef:
    name: aws-efs-cloud-credentials
    namespace: openshift-cluster-csi-drivers
  serviceAccountNames:
  - aws-efs-csi-driver-operator
  - aws-efs-csi-driver-controller-sa
EOF
fi

CCOCTL_OPTIONS=""

if [[ "${STS_USE_PRIVATE_S3}" == "yes" ]]; then
  CCOCTL_OPTIONS=" $CCOCTL_OPTIONS --create-private-s3-bucket "
fi

if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
  CCOCTL_OPTIONS=" $CCOCTL_OPTIONS --enable-tech-preview "
fi

# create required credentials infrastructure and installer manifests
ccoctl aws create-all ${CCOCTL_OPTIONS} --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "Cluster authentication:"
cat "/tmp/manifests/cluster-authentication-02-config.yaml"
echo -e "\n"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done

# for Shared VPC install, same ingress role name, it will be used in trust policy
ingress_role_arn=$(grep -hE "role_arn.*ingress" * | awk '{print $3}')
if [[ ${ingress_role_arn} != "" ]]; then
  echo "Saving ingress role: ${ingress_role_arn}"
  echo "${ingress_role_arn}" > ${SHARED_DIR}/sts_ingress_role_arn
fi
