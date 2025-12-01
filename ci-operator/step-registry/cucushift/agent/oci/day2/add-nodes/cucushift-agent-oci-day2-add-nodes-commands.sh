#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

echo "Creating agent node image..."
dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
source "${SHARED_DIR}"/platform-conf.sh
CONTENT=$(<"${CLUSTER_PROFILE_DIR}"/oci-privatekey)
export OCI_CLI_KEY_CONTENT=${CONTENT}

oc adm node-image create --dir="${dir}" --mac-address=c8:4b:d6:86:eb:4e -a "${CLUSTER_PROFILE_DIR}/pull-secret" --root-device-hint='deviceName:/dev/sdb' --insecure=true

echo "uploading node.iso to iso-datastore.."

oci os object put -bn "${BUCKET_NAME}" --file node.x86_64.iso -ns "${NAMESPACE_NAME}"

echo "start debugging...."
sleep 4h