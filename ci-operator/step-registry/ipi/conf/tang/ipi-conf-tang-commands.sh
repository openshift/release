#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

workdir=`mktemp -d`

SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

#Download butane
curl -sSL "https://mirror2.openshift.com/pub/openshift-v4/clients/butane/latest/butane" --output /tmp/butane && chmod +x /tmp/butane

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm /tmp/pull-secret
echo "ocp_version: ${ocp_version}"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

TANG_SERVER_KEY=$(ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i "${SSH_PRIV_KEY_PATH}" ${BASTION_SSH_USER}@${BASTION_IP} "sudo podman exec -it tang tang-show-keys 8080")

declare -a roles=("master" "worker")
ret_code=0
for butane_version in "${butane_version_list[@]}"; do
  for role in "${roles[@]}"; do
    cat > "${workdir}/${role}_tang_disk_encryption.bu" << EOF
variant: openshift
version: ${butane_version}
metadata:
  name: ${role}-storage
  labels:
    machineconfiguration.openshift.io/role: ${role}
boot_device:
  layout: x86_64
  luks:
    tang:
      - url: http://${BASTION_IP}:7500
        thumbprint: ${TANG_SERVER_KEY}
    threshold: 1
EOF
    /tmp/butane "${workdir}/${role}_tang_disk_encryption.bu" > "${workdir}/manifest_${role}_tang_disk_encryption.yml" || ret_code=$?
    [ ${ret_code} -ne 0 ] && echo "Butane failed to transform '${role}-tang_disk_encryption.bu' to machineconfig file using version '${butane_version}' (non-GA?)." && break
    cp "${workdir}/manifest_${role}_tang_disk_encryption.yml" "${SHARED_DIR}/manifest_${role}_tang_disk_encryption.yml"
    cp "${workdir}/manifest_${role}_tang_disk_encryption.yml" "${ARTIFACT_DIR}/manifest_${role}_tang_disk_encryption.yml"
  done
  # skip other versions from the array if current one was successful (GA scenario or non-GA 2nd run)
  [ ${ret_code} -eq 0 ] && break
done
# abort if all versions from the array have failed
if [ ${ret_code} -ne 0 ]; then
  echo "Butane failed to transform storage templates into machineconfig files. Aborting execution."
  exit 1
fi
