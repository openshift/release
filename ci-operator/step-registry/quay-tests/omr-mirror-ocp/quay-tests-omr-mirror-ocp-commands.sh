#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Check oc and ocp installer version
echo "What's the oc version?"
oc version

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"

echo "What's the ocp installer version?"
openshift-install version

echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" || true

cat ${CLUSTER_PROFILE_DIR}/pull-secret || true

OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
echo "Start to mirror OCP Images to OMR $OMR_HOST_NAME ..."

cp /var/run/quay-qe-omr-secret/quaybuilder ${SHARED_DIR}/quaybuilder && cp /var/run/quay-qe-omr-secret/quaybuilder.pub  ${SHARED_DIR}/quaybuilder.pub || true
chmod 600 ${SHARED_DIR}/quaybuilder && chmod 600 ${SHARED_DIR}/quaybuilder.pub || true

#Share the CA Cert of Quay OMR
scp -i quaybuilder -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  ec2-user@"${OMR_HOST_NAME}":/etc/quay-install/quay-rootCA/rootCA.pem ${SHARED_DIR} || true

target_release_image_repo="${OMR_HOST_NAME}:8443/openshift-release-dev/ocp-release"
target_release_image="${target_release_image_repo}:4.12-x86_64"

echo "${target_release_image_repo}" || true
echo "${target_release_image}" || true

cat >> "${new_pull_secret}" << EOF
{
  "auths": {
    "${OMR_HOST_NAME}:8443": {
      "auth": "cXVheTpwYXNzd29yZA==",
      "email": "quay-qe@redhat.com"
    }
  }
}
EOF

# MIRROR IMAGES
oc adm release -a "${new_pull_secret}" mirror --insecure=true \
 --from=${OPENSHIFT_INSTALL_RELEASE_IMAGE} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image} | tee "${mirror_output}" || true

#debug
sleep 500
