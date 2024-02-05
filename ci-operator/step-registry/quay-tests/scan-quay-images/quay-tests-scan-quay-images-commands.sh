#!/bin/bash

set -euo pipefail

#Retrieve the Quay Security Testing Hostname
quay_security_testing_hostname =$(cat ${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME)

#Retrieve the public key of Quay Security Testing Hostname
cp /var/run/quay-qe-omr-secret/quaybuilder.pub .
chmod 600 ./quaybuilder.pub

quay_operator_image="brew.registry.redhat.io/rh-osbs/$QUAY_OPERATOR_IMAGE"
quay_app_image="brew.registry.redhat.io/rh-osbs/$QUAY_IMAGE"
quay_clair_image="brew.registry.redhat.io/rh-osbs/$QUAY_CLAIR_IMAGE"
quay_bridge_operator_image="brew.registry.redhat.io/rh-osbs/$QUAY_BRIDGE_OPERATOR_IMAGE"
quay_container_security_operator_image="brew.registry.redhat.io/rh-osbs/$QUAY_CONTAINER_SECURITY_OPERATOR_IMAGE"
quay_builder_image="brew.registry.redhat.io/rh-osbs/$QUAY_BUILDER_IMAGE"
quay_builder_qemu_image="brew.registry.redhat.io/rh-osbs/$QUAY_BUILDER_QEMU_IMAGE"
      
function scan_quay_images(){
    ssh -i quaybuilder -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null centos@$1 "sudo /usr/local/bin/grype $2 --scope all-layers > $3_image_vulnerability-report" || true
    scp -i quaybuilder -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null centos@$1:/home/centos/$3_image_vulnerability-report $ARTIFACT_DIR/$3_image_vulnerability-report || true
}

scan_quay_images $quay_security_testing_hostname $quay_operator_image "quay_operator"
scan_quay_images $quay_security_testing_hostname $quay_app_image "quay_app"
scan_quay_images $quay_security_testing_hostname $quay_clair_image "quay_clair"
scan_quay_images $quay_security_testing_hostname $quay_bridge_operator_image "quay_bridge_operator"
scan_quay_images $quay_security_testing_hostname $quay_container_security_operator_image "quay_container_security_operator"
scan_quay_images $quay_security_testing_hostname $quay_builder_image "quay_builder"
scan_quay_images $quay_security_testing_hostname $quay_builder_qemu_image "quay_builder_qemu"
