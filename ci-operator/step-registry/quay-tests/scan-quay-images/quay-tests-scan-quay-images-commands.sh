#!/bin/bash

set -euo pipefail

#Retrieve the Quay Security Testing Hostname
quay_security_testing_hostname="$(cat ${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME)"

#Retrieve the Credentials of image registry "brew.registry.redhat.io"
QUAY_BREW_USERNAME=$(cat /var/run/quay-qe-brew-secret/username)
QUAY_BREW_PASSWORD=$(cat /var/run/quay-qe-brew-secret/password)

#Retrieve the private key of Quay Security Testing Hostname
cp /var/run/quay-qe-omr-secret/quaybuilder /tmp && cd /tmp && chmod 600 quaybuilder && echo "" >>quaybuilder || true

quay_operator_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_OPERATOR_IMAGE}"
quay_app_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_IMAGE}"
quay_clair_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_CLAIR_IMAGE}"
quay_bridge_operator_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_BRIDGE_OPERATOR_IMAGE}"
quay_container_security_operator_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE}"
quay_builder_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_BUILDER_IMAGE}"
quay_builder_qemu_image_tag="brew.registry.redhat.io/rh-osbs/${QUAY_BUILDER_QEMU_IMAGE}"
      
function scan_quay_images(){
    ssh -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1 "sudo trivy image $2 --username '${QUAY_BREW_USERNAME}' --password ${QUAY_BREW_PASSWORD} > $3_image_vulnerability-report" || true
    scp -o StrictHostKeyChecking=no -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@$1:/home/ec2-user/$3_image_vulnerability-report $ARTIFACT_DIR/$3_image_vulnerability-report || true
}

echo "start to scan quay images:"
scan_quay_images "$quay_security_testing_hostname" "$quay_operator_image_tag" "quay_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_app_image_tag" "quay_app"
scan_quay_images "$quay_security_testing_hostname" "$quay_clair_image_tag" "quay_clair"
scan_quay_images "$quay_security_testing_hostname" "$quay_bridge_operator_image_tag" "quay_bridge_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_container_security_operator_image_tag" "quay_container_security_operator"
scan_quay_images "$quay_security_testing_hostname" "$quay_builder_image_tag" "quay_builder"
scan_quay_images "$quay_security_testing_hostname" "$quay_builder_qemu_image_tag" "quay_builder_qemu"

echo "completed scanning quay images, pls check the scan results in artifact directory."