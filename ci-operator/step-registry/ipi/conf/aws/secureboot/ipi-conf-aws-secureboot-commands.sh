#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${AWS_SECUREBOOT_ENABLED}" != "true" ]]; then
  echo "AWS_SECUREBOOT_ENABLED is not 'true', skipping secure boot configuration"
  exit 0
fi

echo "Configuring UEFI Secure Boot for AWS worker nodes"

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE}}"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${REGION}"

RESOURCES_FILE="${SHARED_DIR}/secureboot-resources.txt"
echo "REGION=${REGION}" > "${RESOURCES_FILE}"

cleanup_on_error() {
  echo "ERROR: Secure Boot setup failed, cleaning up resources..."
  if [[ -f "${RESOURCES_FILE}" ]]; then
    local ami_id snapshot_id
    ami_id=$(grep -oP '^AMI_ID=\K.+' "${RESOURCES_FILE}" || true)
    snapshot_id=$(grep -oP '^SNAPSHOT_ID=\K.+' "${RESOURCES_FILE}" || true)
    if [[ -n "${ami_id}" ]]; then
      echo "Deregistering AMI: ${ami_id}"
      aws ec2 deregister-image --image-id "${ami_id}" 2>/dev/null || true
    fi
    if [[ -n "${snapshot_id}" ]]; then
      echo "Deleting snapshot: ${snapshot_id}"
      aws ec2 delete-snapshot --snapshot-id "${snapshot_id}" 2>/dev/null || true
    fi
    rm -f "${RESOURCES_FILE}"
  fi
}
trap cleanup_on_error ERR

# Extract openshift-install from the release to get the correct RHCOS AMI
EXTRACT_DIR=$(mktemp -d)
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${EXTRACT_DIR}/pull-secret"
oc registry login --to "${EXTRACT_DIR}/pull-secret"
SECUREBOOT_RELEASE_IMAGE="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-${RELEASE_IMAGE_LATEST}}"
oc adm release extract --registry-config "${EXTRACT_DIR}/pull-secret" --command=openshift-install "${SECUREBOOT_RELEASE_IMAGE}" --to="${EXTRACT_DIR}"

RHCOS_AMI=$("${EXTRACT_DIR}/openshift-install" coreos print-stream-json \
  | jq -r --arg region "${REGION}" '.architectures.x86_64.images.aws.regions[$region].image')

if [[ -z "${RHCOS_AMI}" || "${RHCOS_AMI}" == "null" ]]; then
  echo "ERROR: Could not determine RHCOS AMI for region ${REGION}"
  exit 1
fi
echo "RHCOS AMI for ${REGION}: ${RHCOS_AMI}"

SNAPSHOT_ID=$(aws ec2 describe-images --image-ids "${RHCOS_AMI}" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
echo "Source snapshot: ${SNAPSHOT_ID}"

echo "Copying snapshot to CI account..."
NEW_SNAPSHOT_ID=$(aws ec2 copy-snapshot \
  --source-region "${REGION}" \
  --source-snapshot-id "${SNAPSHOT_ID}" \
  --description "RHCOS snapshot copy for Secure Boot CI" \
  --query 'SnapshotId' --output text)
echo "New snapshot: ${NEW_SNAPSHOT_ID}"
echo "SNAPSHOT_ID=${NEW_SNAPSHOT_ID}" >> "${RESOURCES_FILE}"

echo "Waiting for snapshot copy to complete..."
aws ec2 wait snapshot-completed --snapshot-ids "${NEW_SNAPSHOT_ID}"
echo "Snapshot copy complete"

echo "Installing virt-firmware..."
python3 -m pip install --user --quiet virt-firmware

SB_BLOB=$(mktemp)
if [[ "${AWS_SECUREBOOT_ENROLL_KMM_CERT:-false}" == "true" ]]; then
  # This is the public CA certificate used by the KMM filestosign tests. The
  # private signing key remains in the test repository and is never included
  # in the CI configuration or the firmware image.
  KMM_CERT_B64="MIIFXzCCA0egAwIBAgIUWAIGkfuVm+MhaciUbKhaYm/vr5gwDQYJKoZIhvcNAQELBQAwNjEPMA0GA1UECgwGS01NLVFFMSMwIQYDVQQDDBpLTU0gU2VjdXJlIEJvb3QgU2lnbmluZyBDQTAgFw0yNjA3MjExMTI2MDVaGA8yMTI2MDYyNzExMjYwNVowNjEPMA0GA1UECgwGS01NLVFFMSMwIQYDVQQDDBpLTU0gU2VjdXJlIEJvb3QgU2lnbmluZyBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANAbs93H5JuZi5kazv8ciPajuIHG5WqzbIyzXGNOPf5HZWea0sK9dbqUxMaedq/t+U92UNpeYzcCFd3Jb9Hio4qcbdkudAE+ensJGsQddACDJZDxO+egEdpO2yFVAwn/wSRcdBNyvMVHSMGQZBF5hJU6GR3YlsPB/+l6yK3KUSd+lULuZmlAbjVagdep1Q2QEJxQDWFg/9GpnsuPUuMjuj1lz6UW6TucQM/fe8WnNgb/OUOguOIb37NQVfHRLk8cGzsCXxH6ea7SY4d0cBDUayMnbgwOObl6BGDdoJgS5wnDClaJj026W3OkxhyJUbjauaWV8wXMO17o210u9vJaxxtARK2TG+il62xkbN0QFcGenVMfxDxWNKLLPVKCZCWTrgdEIknqH8swks80S8pQeOikveoGtGe0903gPAYqrVr0vc71wcc1d5uHcoodrznW0ZoCQvN+BJmzRe6aKNJt6C4AKVStmjsSNTwWxQ7Ja8rhrAei0LwiAxIUhULyVRDUtc2yCMkBHhKVpQSBP3GJHdI0HjrT1gbPGoi4m4xKwxjO0AEwCdgbWKZForodZmENHOW++lYQBbC8/ifoLO+vHIHwIliQDnBoPendyFXzcN/Ta+jF2zgTdUydyxxOL2ygnA41A2spxrhZLbDseOQ7aVvluiImoLE9j4LEIhH9QPQNAgMBAAGjYzBhMB8GA1UdIwQYMBaAFFA1AU7fU0EqIFiPRWMonL1yJgQ6MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgKEMB0GA1UdDgQWBBRQNQFO31NBKiBYj0VjKJy9ciYEOjANBgkqhkiG9w0BAQsFAAOCAgEAAfIjOymqeNWq+nxQc2MzbHqzUBqAbTEemdkAsB/wqfXmy0JkKeZkdizwBCkisDkR9eimlY9wKkf2OWQQlTK69JCeu+TfGcY5OPeMfIa81yjgsUVxZPJ9DXmrfsLQIfsQwclJXYxGuuFx5aKHAvjMJcrXSpScP+PPEMvFGNULK0lqLkX//LWL9plcToNL6/auPxno5wbilebdWhdvmSfpowyg9VLS0L2fHkFODVlrCX2SJlgphRoFOjA6XfwTra/EdFDCNIgEiqazmEZpqLFPsaqJ3TB6t6OF87oJCZREZk7Ufq6WYsINLefZGo4rbUY2Llm0vmhNwAUdjiWBrWF7oiIqghZpriqNBXbuA3uCJ+nWJLEtphfuoAufkDsb98C1gJ9IbFOVnWA42LVn9zinTtMsCdXQJYedRdvFRvhJqkeKu7J1O/eeuWVBZ/WhQ81q2sjOvxowxJN9QzJF4IXLAsS3elHHyr5EUaVelaKnv1lF6PSfqQKChBvUgBqQOdxjMS2kzblCv0HRaqtp4u7+YsKnT+zoA+cgq6Sasr4dqUDfTq+BglmPfmk0NIXX20conYVGhIs/IiofcezbYUM1mYVzEeb/vmZeSeO1deYdT0Xsdtr69ma4rc+v1sHU+TDgo+vdR3DGZgt0gR1ODgNxKNxUjnYEpBrJr6eoxLaNzk0="
  KMM_CERT_DER=$(mktemp)
  printf '%s' "${KMM_CERT_B64}" | base64 -d > "${KMM_CERT_DER}"
  ~/.local/bin/virt-fw-vars \
    --enroll-redhat \
    --add-db "${AWS_SECUREBOOT_KMM_CERT_GUID}" "${KMM_CERT_DER}" \
    --add-mok "${AWS_SECUREBOOT_KMM_CERT_GUID}" "${KMM_CERT_DER}" \
    --output-aws "${SB_BLOB}"
  rm -f "${KMM_CERT_DER}"
else
  ~/.local/bin/virt-fw-vars --enroll-redhat --output-aws "${SB_BLOB}"
fi
echo "Generated UEFI Secure Boot variable store"

ROOT_DEVICE=$(aws ec2 describe-images --image-ids "${RHCOS_AMI}" \
  --query 'Images[0].RootDeviceName' --output text)
VOLUME_SIZE=$(aws ec2 describe-images --image-ids "${RHCOS_AMI}" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.VolumeSize' --output text)

AMI_NAME="rhcos-secureboot-ci-${BUILD_ID}-${RANDOM}"
echo "Registering Secure Boot AMI: ${AMI_NAME}"

# Disable tracing due to uefi-data handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SB_AMI_ID=$(aws ec2 register-image \
  --name "${AMI_NAME}" \
  --description "RHCOS with UEFI Secure Boot for CI" \
  --architecture x86_64 \
  --virtualization-type hvm \
  --root-device-name "${ROOT_DEVICE}" \
  --block-device-mappings "[{\"DeviceName\":\"${ROOT_DEVICE}\",\"Ebs\":{\"SnapshotId\":\"${NEW_SNAPSHOT_ID}\",\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
  --ena-support \
  --boot-mode uefi \
  --uefi-data "$(cat "${SB_BLOB}")" \
  --query 'ImageId' --output text)
$WAS_TRACING && set -x
echo "Registered AMI: ${SB_AMI_ID}"
echo "AMI_ID=${SB_AMI_ID}" >> "${RESOURCES_FILE}"

rm -f "${SB_BLOB}"
rm -rf "${EXTRACT_DIR}"

echo "Waiting for AMI to become available..."
aws ec2 wait image-available --image-ids "${SB_AMI_ID}"
echo "AMI is available"

export SB_AMI_ID
yq-v4 eval -i '.compute[].platform.aws.amiID = env(SB_AMI_ID)' "${CONFIG}"

echo "install-config compute section:"
yq-v4 '.compute' "${CONFIG}"
echo "Secure Boot configuration complete"
