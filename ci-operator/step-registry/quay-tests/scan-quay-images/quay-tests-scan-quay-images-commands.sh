#!/bin/bash

set -euo pipefail

#Retrieve the Quay Security Testing Hostname
quay_security_testing_hostname="$(cat ${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME)"

#Retrieve the Credentials of image registry "registry.redhat.io"
QUAY_REGISTRY_REDHAT_IO_USERNAME=$(cat /var/run/quay-qe-registry-redhat-io-secret/username)
QUAY_REGISTRY_REDHAT_IO_PASSWORD=$(cat /var/run/quay-qe-registry-redhat-io-secret/password)

if [[ "${QUAY_VERSION}" == "3.16" ]]; then
  QUAY_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-v3-16-username)
  QUAY_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-v3-16-password)
  QUAY_CLAIR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-16-username)
  QUAY_CLAIR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-16-password)
  QUAY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-16-username)
  QUAY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-16-password)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-16-username)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-16-password)
  QUAY_BRIDGE_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-16-username)
  QUAY_BRIDGE_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-16-password)
  QUAY_BUILDER_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-16-username)
  QUAY_BUILDER_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-16-password)
  QUAY_BUILDER_QEMU_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-16-username)
  QUAY_BUILDER_QEMU_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-16-password)
fi

if [[ "${QUAY_VERSION}" == "3.15" ]]; then
  QUAY_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-v3-15-username)
  QUAY_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-v3-15-password)
  QUAY_CLAIR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-15-username)
  QUAY_CLAIR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-15-password)
  QUAY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-15-username)
  QUAY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-15-password)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-15-username)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-15-password)
  QUAY_BRIDGE_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-15-username)
  QUAY_BRIDGE_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-15-password)
  QUAY_BUILDER_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-15-username)
  QUAY_BUILDER_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-15-password)
  QUAY_BUILDER_QEMU_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-15-username)
  QUAY_BUILDER_QEMU_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-15-password)
fi

if [[ "${QUAY_VERSION}" == "3.14" ]]; then
  QUAY_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-v3-14-username)
  QUAY_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-v3-14-password)
  QUAY_CLAIR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-14-username)
  QUAY_CLAIR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-clair-v3-14-password)
  QUAY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-14-username)
  QUAY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-operator-v3-14-password)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-14-username)
  QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/container-security-operator-v3-14-password)
  QUAY_BRIDGE_OPERATOR_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-14-username)
  QUAY_BRIDGE_OPERATOR_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-bridge-operator-v3-14-password)
  QUAY_BUILDER_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-14-username)
  QUAY_BUILDER_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-v3-14-password)
  QUAY_BUILDER_QEMU_IMAGE_USERNAME=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-14-username)
  QUAY_BUILDER_QEMU_IMAGE_PASSWORD=$(cat /var/run/quay-qe-konflux-secret/quay-builder-qemu-v3-14-password)
fi

#Retrieve the private key of Quay Security Testing Hostname
cp /var/run/quay-qe-omr-secret/quaybuilder /tmp && cd /tmp && chmod 600 quaybuilder && echo "" >>quaybuilder || true

QUAY_KONFLUX_BASE_PATH="quay.io/redhat-user-workloads/quay-eng-tenant"

quay_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_OPERATOR_IMAGE}"
quay_app_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_IMAGE}"
quay_clair_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_CLAIR_IMAGE}"
quay_bridge_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BRIDGE_OPERATOR_IMAGE}"
quay_container_security_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE}"
quay_builder_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BUILDER_IMAGE}"
quay_builder_qemu_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BUILDER_QEMU_IMAGE}"
quay_redis_image_tag="${QUAY_REDIS_IMAGE}"
      
function scan_quay_images(){
    ssh -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1 "sudo trivy image $2 --username $3 --password $4 > $5_image_vulnerability-report" || true
    scp -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1:/home/ec2-user/$5_image_vulnerability-report $ARTIFACT_DIR/$5_image_vulnerability-report || true
}

function scan_quay_redis_images(){
    ssh -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1 "sudo trivy image $2 --username '${QUAY_REGISTRY_REDHAT_IO_USERNAME}' --password ${QUAY_REGISTRY_REDHAT_IO_PASSWORD} > $3_image_vulnerability-report" || true
    scp -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1:/home/ec2-user/$3_image_vulnerability-report $ARTIFACT_DIR/$3_image_vulnerability-report || true
}

echo "start to scan quay images:"
scan_quay_images "$quay_security_testing_hostname" "$quay_operator_image_tag" "$QUAY_OPERATOR_IMAGE_USERNAME" "$QUAY_OPERATOR_IMAGE_PASSWORD" "quay_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_app_image_tag" "$QUAY_IMAGE_USERNAME" "$QUAY_IMAGE_PASSWORD" "quay_app"
scan_quay_images "$quay_security_testing_hostname" "$quay_clair_image_tag" "$QUAY_CLAIR_IMAGE_USERNAME" "$QUAY_CLAIR_IMAGE_PASSWORD" "quay_clair"
scan_quay_images "$quay_security_testing_hostname" "$quay_bridge_operator_image_tag" "$QUAY_BRIDGE_OPERATOR_IMAGE_USERNAME" "$QUAY_BRIDGE_OPERATOR_IMAGE_PASSWORD" "quay_bridge_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_container_security_operator_image_tag" "$QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_USERNAME" "$QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_PASSWORD" "quay_container_security_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_builder_image_tag" "$QUAY_BUILDER_IMAGE_USERNAME" "$QUAY_BUILDER_IMAGE_PASSWORD" "quay_builder"
scan_quay_images "$quay_security_testing_hostname" "$quay_builder_qemu_image_tag" "$QUAY_BUILDER_QEMU_IMAGE_USERNAME" "$QUAY_BUILDER_QEMU_IMAGE_PASSWORD" "quay_builder_qemu"

scan_quay_redis_images "$quay_security_testing_hostname" "$quay_redis_image_tag" "quay_redis"

echo "completed scanning quay images, pls check the scan results in artifact directory."