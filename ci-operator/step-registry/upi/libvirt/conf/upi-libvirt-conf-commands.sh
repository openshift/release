#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# install jq if not installed
if ! [ -x "$(command -v jq)" ]; then
    mkdir -p /tmp/bin
    JQ_CHECKSUM="2f312b9587b1c1eddf3a53f9a0b7d276b9b7b94576c85bda22808ca950569716"
    curl -Lo /tmp/bin/jq "https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64"

    actual_checksum=$(sha256sum /tmp/bin/jq | cut -d ' ' -f 1)
    if [ "${actual_checksum}" != "${JQ_CHECKSUM}" ]; then
        echo "Checksum of downloaded JQ didn't match expected checksum"
        exit 1
    fi

    chmod +x /tmp/bin/jq
    export PATH=${PATH}:/tmp/bin
fi

# install yq
curl -o /tmp/bin/yq -L "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" && chmod u+x /tmp/bin/yq

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

# ensure hostname can be found
HOSTNAME="$(jq -r ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for $REMOTE_LIBVIRT_URI"

# ensure RELEASE_IMAGE_LATEST is set
if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

echo "Installing from initial release ${RELEASE_IMAGE_LATEST}"
openshift-install version
CONFIG="${SHARED_DIR}/install-config.yaml"

# TODO: define a leased resource uniquely for the multiarch compute deployments to re-enable the
#   multiarch-compute job cluster name below, and make a ${WORKER_REPLICAS} replacement value for
#   the config to start at 0 workers at deploy time for the z multiarch compute efforts.
# CLUSTER_NAME="libvirt-s390x-amd64-0-0"
# BASE_DOMAIN="ci"

if [[ ${COMPUTE_ENV_TYPE} == "heterogeneous" ]]; then
  CLUSTER_NAME="libvirt-s390x-amd64-0-0"
  BASE_DOMAIN="ci"
  WORKER_REPLICAS=0
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
  CLUSTER_SUBNET="$(jq -r ".\"${LEASED_RESOURCE}\".subnet" "${CLUSTER_PROFILE_DIR}/leases")"
fi

cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_REPLICAS}
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
fips: ${FIPS_ENABLED}
EOF

cat "${CONFIG}"

yq eval ".pullSecret = load_str(\"${CLUSTER_PROFILE_DIR}/pull-secret\")" -i "${CONFIG}"
yq eval ".sshKey = load_str(\"${CLUSTER_PROFILE_DIR}/ssh-publickey\")" -i "${CONFIG}"