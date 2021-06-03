#!/usr/bin/env bash

#https://github.com/openshift/installer/blob/master/docs/user/openstack/install_upi.md#red-hat-enterprise-linux-coreos-rhcos
# This should upload image and if available
# setup hw_qemu_guest_agent=yes
# container executing needs large size of storage
set -o nounset
set -o errexit
set -o pipefail



INFRA_ID=$(<"${SHARED_DIR}"/INFRA_ID)

ASSETS_DIR=/tmp/assets_dir
rm -rf "${ASSETS_DIR}"
mkdir -p "${ASSETS_DIR}/"
export RHCOS_GLANCE_IMAGE_NAME=${INFRA_ID}-rhcos-${RHCOS_RELEASE}
rm -rf "${ASSETS_DIR}"/rhcos.json
IMAGE_SOURCE=https://raw.githubusercontent.com/openshift/installer/${RHCOS_RELEASE}/data/data/rhcos.json
wget -q -O "${ASSETS_DIR}"/rhcos.json "$IMAGE_SOURCE"
GZ_IMAGE_FILENAME=$(grep path "${ASSETS_DIR}"/rhcos.json | grep openstack |awk '{print $2}' | awk -F\" '{print $2}')
BASEURI=$(grep base "${ASSETS_DIR}"/rhcos.json | awk '{print $2}' |awk -F\" '{print $2}')
wget  -q -O "${ASSETS_DIR}"/"$GZ_IMAGE_FILENAME" "$BASEURI""$GZ_IMAGE_FILENAME"
gunzip -f "${ASSETS_DIR}"/"$GZ_IMAGE_FILENAME"
IMAGE_FILENAME=${GZ_IMAGE_FILENAME%.gz}
IMAGE_ID=$(openstack image create --container-format=bare --disk-format=qcow2 --file "${ASSETS_DIR}"/"$IMAGE_FILENAME" "$RHCOS_GLANCE_IMAGE_NAME" -f value -c id)
echo "$IMAGE_ID" >> "${SHARED_DIR}"/RHCOS_IMAGE_ID
echo "$IMAGE_ID" >> "${SHARED_DIR}"/DELETE_IMAGES

rm -rf "${ASSETS_DIR}"/*