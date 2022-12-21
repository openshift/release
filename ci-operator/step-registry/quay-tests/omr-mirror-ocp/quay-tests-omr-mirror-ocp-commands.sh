#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Check oc and ocp installer version
echo "What's the oc version?"
oc version

echo "What's the ocp installer version?"
openshift-install version

echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" || true

OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
echo "Start to mirror OCP Images to OMR $OMR_HOST_NAME ..."

cp /var/run/quay-qe-omr-secret/quaybuilder . && cp /var/run/quay-qe-omr-secret/quaybuilder.pub .
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub

#Share the CA Cert of Quay OMR
scp -i quaybuilder -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  ec2-user@"${OMR_HOST_NAME}":/etc/quay-install/quay-rootCA/rootCA.pem ${SHARED_DIR} || true

sleep 500
