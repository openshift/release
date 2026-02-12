#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
HOSTNAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
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

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
if [[ "${LEASED_RESOURCE}" == *ppc64le* ]]; then
  CLUSTER_NAME="${LEASED_RESOURCE}"
fi
CLUSTER_SUBNET="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".subnet" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${CLUSTER_SUBNET}" ]]; then
  echo "Failed to lookup subnet"
  exit 1
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
networking:
  clusterNetwork:
  - cidr: 10.8.0.0/14
    hostPrefix: 23
  machineCIDR: 192.168.${CLUSTER_SUBNET}.0/24
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_REPLICAS}
platform:
  libvirt:
    URI: ${REMOTE_LIBVIRT_URI}
    network:
      dnsmasqOptions:
      - name: "address"
        value: "/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/192.168.${CLUSTER_SUBNET}.1"
      if: "br$(printf ${LEASED_RESOURCE} | tail -c 3)"
EOF
cat "${CONFIG}"

cat >> "${CONFIG}" << EOF
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	cat >> "${CONFIG}" << EOF
fips: true
EOF
fi
