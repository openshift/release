#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

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

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

CONFIG="${SHARED_DIR}/install-config.yaml"
STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

MACHINE_POOL_OVERRIDES=""
RESOURCE_POOL_DEF=""
set +o errexit
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc registry login

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

VERSION=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)

set -o errexit

Z_VERSION=1000

if [ ! -z ${VERSION} ]; then
  Z_VERSION=$(echo ${VERSION} | cut -d'.' -f2)
  echo "$(date -u --rfc-3339=seconds) - determined version is 4.${Z_VERSION}"
else 
  echo "$(date -u --rfc-3339=seconds) - unable to determine y stream, assuming this is master"
fi

if [ ${Z_VERSION} -gt 9 ]; then
    echo "$(date -u --rfc-3339=seconds) - 4.x installation is later than 4.9, will install with resource pool"
    RESOURCE_POOL_DEF="resourcePool: /${vsphere_datacenter}/host/${vsphere_cluster}/Resources/ipi-ci-clusters"
fi
if [ ${Z_VERSION} -lt 11 ]; then
  MACHINE_POOL_OVERRIDES="controlPlane:
  name: master
  replicas: 3
  platform:
    vsphere:
      osDisk:
        diskSizeGB: 120
compute:
- name: worker
  replicas: 3
  platform:
    vsphere:
      cpus: 4
      coresPerSocket: 1
      memoryMB: 16384
      osDisk:
        diskSizeGB: 120"
fi

if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        echo "Compact SIZE_VARIANT was configured, setting worker's replicas to 0"
        MACHINE_POOL_OVERRIDES="controlPlane:
  name: master
  replicas: 3
  platform:
    vsphere:
      cpus: 8
      memoryMB: 32768
      osDisk:
        diskSizeGB: 120
compute:
- name: worker
  replicas: 0"
fi

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
$MACHINE_POOL_OVERRIDES
platform:
  vsphere:
    vcenter: "${vsphere_url}"
    datacenter: "${vsphere_datacenter}"
    defaultDatastore: "${vsphere_datastore}"
    cluster: "${vsphere_cluster}"
    network: "${LEASED_RESOURCE}"
    password: "${GOVC_PASSWORD}"
    username: "${GOVC_USERNAME}"
    ${RESOURCE_POOL_DEF}
EOF

if [ -f ${SHARED_DIR}/external_lb ]; then 
  echo "$(date -u --rfc-3339=seconds) - external load balancer in use, not setting VIPs"
else
cat >> "${CONFIG}" << EOF
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
EOF
fi

if [ -f "${SHARED_DIR}"/enable_template_content.txt ]; then
  echo "$(date -u --rfc-3339=seconds) - tamplate defined, appending to platform spec"
  cat "${SHARED_DIR}"/enable_template_content.txt >> ${CONFIG}
fi

if [ -f ${STATIC_IPS} ]; then
  echo "$(date -u --rfc-3339=seconds) - static IPs defined, appending to platform spec"
  cat ${STATIC_IPS} >> ${CONFIG}
fi

cat >> "${CONFIG}" << EOF
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

if [ ${Z_VERSION} -gt 9 ]; then
  PULL_THROUGH_CACHE_DISABLE="/var/run/vault/vsphere-config/pull-through-cache-disable"
  CACHE_FORCE_DISABLE="false"
  if [ -f "${PULL_THROUGH_CACHE_DISABLE}" ]; then
    CACHE_FORCE_DISABLE=$(cat ${PULL_THROUGH_CACHE_DISABLE})
  fi

  if [ ${CACHE_FORCE_DISABLE} == "false" ]; then
    if [ ${PULL_THROUGH_CACHE} == "enabled" ]; then
      echo "$(date -u --rfc-3339=seconds) - pull-through cache enabled for job"
      PULL_THROUGH_CACHE_CREDS="/var/run/vault/vsphere-config/pull-through-cache-secret"
      PULL_THROUGH_CACHE_CONFIG="/var/run/vault/vsphere-config/pull-through-cache-config"
      PULL_SECRET="/var/run/secrets/ci.openshift.io/cluster-profile/pull-secret"
      TMP_INSTALL_CONFIG="/tmp/tmp-install-config.yaml"
      if [ -f ${PULL_THROUGH_CACHE_CREDS} ]; then    
        echo "$(date -u --rfc-3339=seconds) - pull-through cache credentials found. updating pullSecret"
        cat ${CONFIG} | sed '/pullSecret/d' > ${TMP_INSTALL_CONFIG}2
        cat ${TMP_INSTALL_CONFIG}2 | sed '/\"auths\"/d' > ${TMP_INSTALL_CONFIG}
        jq -cs '.[0] * .[1]' ${PULL_SECRET} ${PULL_THROUGH_CACHE_CREDS} > /tmp/ps-combined.json
        echo -e "\npullSecret: '""$(cat /tmp/ps-combined.json)""'" >> ${TMP_INSTALL_CONFIG}
        cat ${TMP_INSTALL_CONFIG} > ${CONFIG}
      else
        echo "$(date -u --rfc-3339=seconds) - pull-through cache credentials not found. not updating pullSecret"
      fi
      if [ -f ${PULL_THROUGH_CACHE_CONFIG} ]; then
        echo "$(date -u --rfc-3339=seconds) - pull-through cache configuration found. updating install-config"
        cat ${PULL_THROUGH_CACHE_CONFIG} >> ${CONFIG}
      else
        echo "$(date -u --rfc-3339=seconds) - pull-through cache configuration not found. not updating install-config"
      fi
    fi
  else 
    echo "$(date -u --rfc-3339=seconds) - pull-through cache force disabled"
  fi
fi
