#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_url
declare vsphere_cluster
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
oc registry login

function getVersion() {
  local release_image=""
  if [ -n "${RELEASE_IMAGE_INITIAL-}" ]; then
    release_image=${RELEASE_IMAGE_INITIAL}
  elif [ -n "${RELEASE_IMAGE_LATEST-}" ]; then
    release_image=${RELEASE_IMAGE_LATEST}     
  fi
  
  local version=""
  if [ ${release_image} != "" ]; then
    version=$(oc adm release info ${release_image} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)    
  fi
  echo "${version}"
}

VERSION=$(getVersion)
if [ -z "${RHCOS_VM_TEMPLATE}" ]; then
  installer_bin=$(which openshift-install)
  ova_url=$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')
  echo "${ova_url}" > "${SHARED_DIR}"/ova_url.txt
  vm_template="${ova_url##*/}"

# select a hardware version for testing
  vsphere_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $1}')
  hw_versions=(15 17 18 19)
  if [[ ${vsphere_version} -eq 8 ]]; then
      hw_versions=(20)
  fi
  hw_available_versions=${#hw_versions[@]}
  selected_hw_version_index=$((RANDOM % ${hw_available_versions}))
  target_hw_version=${hw_versions[$selected_hw_version_index]}
  echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"
  vm_template=${vm_template}-hw${target_hw_version}
  
else
  vm_template="${RHCOS_VM_TEMPLATE}"
fi

Z_VERSION=$(echo ${VERSION} | cut -d'.' -f2)
if [ ${Z_VERSION} -gt 13 ]; then
    cat >> "${SHARED_DIR}"/enable_template_content.txt << EOF
    failureDomains:
    - name: generated-failure-domain
      region: generated-region
      server: "${vsphere_url}"
      topology:
        computeCluster: /${vsphere_datacenter}/host/${vsphere_cluster}
        datacenter: ${vsphere_datacenter}
        datastore: /${vsphere_datacenter}/datastore/${vsphere_datastore}
        template: /${vsphere_datacenter}/vm/${vm_template}
        networks:
        - ${LEASED_RESOURCE}
      zone: generated-zone
EOF
else
    echo "$VERSION does not support template setting"
    exit 1    
fi
