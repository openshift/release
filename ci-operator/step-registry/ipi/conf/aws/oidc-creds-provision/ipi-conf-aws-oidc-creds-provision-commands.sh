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

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

oc registry login
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" ${ADDITIONAL_OC_EXTRACT_ARGS} "${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
echo "CR manifest files:"
ls "/tmp/credrequests"

if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  echo "Shared VPC is enabled"
  echo "Checking if ingress CR file exits"
  ingress_cr_file=$(grep -lr "namespace: openshift-ingress-operator" /tmp/credrequests/) || exit 1
  echo "Ingress CR file: ${ingress_cr_file}"
  echo "Ingress CR content (initial):"
  cat ${ingress_cr_file}

  # x.y.z
  ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} -ojsonpath="{.metadata.version}" | cut -d. -f 1,2)
  ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
  ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
  echo "OCP version: ${ocp_version}"
  
  if (( ocp_minor_version <= 13 && ocp_major_version == 4 )); then
    if ! grep "sts:AssumeRole" ${ingress_cr_file}; then
      echo "WARN: Adding sts:AssumeRole to ingress role"
      sed -i '/      - tag:GetResources/a\ \ \ \ \ \ - sts:AssumeRole' ${ingress_cr_file}
    fi
  fi
  echo "Ingress CR content:"
  cat ${ingress_cr_file}
fi

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
