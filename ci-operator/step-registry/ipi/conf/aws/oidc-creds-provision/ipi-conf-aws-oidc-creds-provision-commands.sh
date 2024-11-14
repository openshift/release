#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${UNIQUE_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

# extract aws credentials requests from the release image
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=aws --to="/tmp/credrequests" ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"
popd

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
  ocp_version=$(oc adm release info --registry-config "${dir}/pull-secret" ${TESTING_RELEASE_IMAGE} -ojsonpath="{.metadata.version}" | cut -d. -f 1,2)
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

rm -f "${dir}/pull-secret"

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
ccoctl_ouptut="/tmp/ccoctl_output"
ccoctl aws create-all ${CCOCTL_OPTIONS} --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp" 2>&1 | tee "${ccoctl_ouptut}"

# save oidc_provider info for upgrade
oidc_provider_arn=$(grep "Identity Provider created with ARN:" "${ccoctl_ouptut}" | awk -F"ARN: " '{print $NF}' || true)
if [[ -n "${oidc_provider_arn}" ]]; then
  echo "Saving oidc_provider_arn: ${oidc_provider_arn}"
  echo "${oidc_provider_arn}" > "${SHARED_DIR}/aws_oidc_provider_arn"
else
  echo "Did not find Identity Provider ARN"
  exit 1
fi

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "Cluster authentication:"
cat "/tmp/manifests/cluster-authentication-02-config.yaml"
echo -e "\n"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done

# for Shared VPC install, same ingress role name, it will be used in trust policy
ingress_role_arn=$(grep -hE "role_arn.*ingress" * | awk '{print $3}' || true)
if [[ ${ingress_role_arn} != "" ]]; then
  echo "Saving ingress role: ${ingress_role_arn}"
  echo "${ingress_role_arn}" > ${SHARED_DIR}/sts_ingress_role_arn
fi
