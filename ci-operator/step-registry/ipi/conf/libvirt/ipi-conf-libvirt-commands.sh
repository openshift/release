#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# mikefarah/yq v4: "yq-v4" uses legacy CLI ("yq-v4 -o=y ..."). Images that only ship "yq" (e.g. OCP 4.8)
# require the v4 syntax: "yq eval -o=y ..." (plain "yq -o=y" treats the expression as a subcommand).
if ! command -v yq-v4 >/dev/null 2>&1 && ! command -v yq >/dev/null 2>&1; then
  echo "Neither yq-v4 nor yq found in PATH"
  exit 1
fi

yq_libvirt_get() {
  local field=$1
  local leases="${CLUSTER_PROFILE_DIR}/leases"
  if command -v yq-v4 >/dev/null 2>&1; then
    yq-v4 -oy ".[\"${LEASED_RESOURCE}\"].${field}" "${leases}"
  else
    yq eval -o=y ".[\"${LEASED_RESOURCE}\"].${field}" "${leases}"
  fi
}

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
HOSTNAME="$(yq_libvirt_get hostname)"
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

CLUSTER_SUBNET="$(yq_libvirt_get subnet)"
if [[ -z "${CLUSTER_SUBNET}" ]]; then
  echo "Failed to lookup subnet"
  exit 1
fi

# Match upi-conf-libvirt / upi-conf-libvirt-network when using IBM Z VPN (phc-cicd) CI.
if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
  LIBVIRT_NETWORK_IF="ocp${CLUSTER_SUBNET}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
  if [[ "${LEASED_RESOURCE}" == *ppc64le* ]]; then
    CLUSTER_NAME="${LEASED_RESOURCE}"
  fi
  LIBVIRT_NETWORK_IF="br$(printf ${LEASED_RESOURCE} | tail -c 3)"
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
      if: "${LIBVIRT_NETWORK_IF}"
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
