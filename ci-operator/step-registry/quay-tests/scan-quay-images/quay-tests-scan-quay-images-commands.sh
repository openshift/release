#!/bin/bash

set -euo pipefail

# Retrieve Quay Security Testing Hostname
quay_security_testing_hostname="$(cat "${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME")"

# Helper function to read secrets from Konflux
read_secret() {
  cat "/var/run/quay-qe-konflux-secret/${1}-v${QUAY_VERSION//./-}-${2}"
}

# Retrieve registry.redhat.io credentials
# shellcheck disable=SC2034  # Used indirectly via scan_configs array
QUAY_REGISTRY_REDHAT_IO_USERNAME=$(cat /var/run/quay-qe-registry-redhat-io-secret/username)
# shellcheck disable=SC2034  # Used indirectly via scan_configs array
QUAY_REGISTRY_REDHAT_IO_PASSWORD=$(cat /var/run/quay-qe-registry-redhat-io-secret/password)

# Define component list
components=(
  "quay" "quay-clair" "quay-operator" "container-security-operator"
  "quay-bridge-operator" "quay-builder" "quay-builder-qemu"
)

# Load credentials for all components based on QUAY_VERSION
for component in "${components[@]}"; do
  var_prefix=$(echo "$component" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  eval "${var_prefix}_IMAGE_USERNAME=\$(read_secret '$component' 'username')"
  eval "${var_prefix}_IMAGE_PASSWORD=\$(read_secret '$component' 'password')"
done

# Retrieve private key and prepare SSH
cp /var/run/quay-qe-omr-secret/quaybuilder /tmp && cd /tmp && chmod 600 quaybuilder && echo "" >>quaybuilder || true

# Configure image paths
QUAY_KONFLUX_BASE_PATH="quay.io/redhat-user-workloads/quay-eng-tenant"

quay_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_OPERATOR_IMAGE}"
quay_app_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_IMAGE}"
quay_clair_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_CLAIR_IMAGE}"
quay_bridge_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BRIDGE_OPERATOR_IMAGE}"
quay_container_security_operator_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE}"
quay_builder_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BUILDER_IMAGE}"
quay_builder_qemu_image_tag="${QUAY_KONFLUX_BASE_PATH}/${QUAY_BUILDER_QEMU_IMAGE}"
quay_redis_image_tag="${QUAY_REDIS_IMAGE}"

# Common SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder"

# Unified scan function
scan_image() {
  local host=$1 image=$2 username=$3 password=$4 name=$5
  ssh $SSH_OPTS "ec2-user@${host}" "sudo trivy image '${image}' --username '${username}' --password '${password}' > ${name}_image_vulnerability-report" || true
  scp $SSH_OPTS "ec2-user@${host}:/home/ec2-user/${name}_image_vulnerability-report" "${ARTIFACT_DIR}/${name}_image_vulnerability-report" || true
}

echo "Start scanning Quay images..."

# Define image scan configurations (image:username_var:password_var)
declare -A scan_configs=(
  ["quay_operator"]="${quay_operator_image_tag}:QUAY_OPERATOR_IMAGE_USERNAME:QUAY_OPERATOR_IMAGE_PASSWORD"
  ["quay_app"]="${quay_app_image_tag}:QUAY_IMAGE_USERNAME:QUAY_IMAGE_PASSWORD"
  ["quay_clair"]="${quay_clair_image_tag}:QUAY_CLAIR_IMAGE_USERNAME:QUAY_CLAIR_IMAGE_PASSWORD"
  ["quay_bridge_operator"]="${quay_bridge_operator_image_tag}:QUAY_BRIDGE_OPERATOR_IMAGE_USERNAME:QUAY_BRIDGE_OPERATOR_IMAGE_PASSWORD"
  ["quay_container_security_operator"]="${quay_container_security_operator_image_tag}:QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_USERNAME:QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE_PASSWORD"
  ["quay_builder"]="${quay_builder_image_tag}:QUAY_BUILDER_IMAGE_USERNAME:QUAY_BUILDER_IMAGE_PASSWORD"
  ["quay_builder_qemu"]="${quay_builder_qemu_image_tag}:QUAY_BUILDER_QEMU_IMAGE_USERNAME:QUAY_BUILDER_QEMU_IMAGE_PASSWORD"
  ["quay_redis"]="${quay_redis_image_tag}:QUAY_REGISTRY_REDHAT_IO_USERNAME:QUAY_REGISTRY_REDHAT_IO_PASSWORD"
)

# Scan all images
for name in "${!scan_configs[@]}"; do
  IFS=':' read -r image user_var pass_var <<< "${scan_configs[$name]}"
  scan_image "$quay_security_testing_hostname" "$image" "${!user_var}" "${!pass_var}" "$name"
done

echo "Completed scanning Quay images. Check results in artifact directory."
