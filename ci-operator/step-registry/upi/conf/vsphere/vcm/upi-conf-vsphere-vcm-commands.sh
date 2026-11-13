#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "using legacy sibling of this step"
  exit 0
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

function get_arch() {
  ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
  echo "${ARCH}"
}

set +o errexit
# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST,
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with
# user specified image pullspec, to avoid auth error when accessing it, always use build farm
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"
dir=$(mktemp -d)
pushd "${dir}"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" pull-secret
oc registry login --to pull-secret
VERSION=$(oc adm release info --registry-config pull-secret "${TESTING_RELEASE_IMAGE}" --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm pull-secret
popd

FAILURE_DOMAIN_PATH=$SHARED_DIR/fds.txt
FAILURE_DOMAIN_JSON=$SHARED_DIR/fds.json
FIRST=1
function getFailureDomainsWithDSwitch() {
    echo "+getFailureDomainsWithDSwitch"

    FAILURE_DOMAIN_OUT="[]"

    echo "[" > ${FAILURE_DOMAIN_PATH}

    # append_failure_domain emits one failure-domain entry for the pool whose
    # env vars (GOVC_*) are currently sourced and whose compute cluster is $1.
    function append_failure_domain() {
      local CLUSTER=$1

      if [ ${FIRST} == 0 ]; then
          echo "    }," >> ${FAILURE_DOMAIN_PATH}
      fi
      echo "    {" >> ${FAILURE_DOMAIN_PATH}
      FIRST=0

      DVS=$(jq --compact-output -r '."'"/${GOVC_DATACENTER}/network/$GOVC_NETWORK"'"' "${SHARED_DIR}"/dvs.json)
      echo "DVS: ${DVS}"

      echo "getting DVS UUID for cluster ${CLUSTER}"

      DVS_UUID=$(echo "$DVS" | jq -r '.cluster["'"${CLUSTER}"'"]')

      echo "DVS UUID ${DVS_UUID}"

      datastoreName=$(basename "${GOVC_DATASTORE}")

      {
        echo "        server = \"${GOVC_URL}\""
        echo "        datacenter = \"${GOVC_DATACENTER}\""
        echo "        cluster = \"${CLUSTER}\""
        echo "        datastore = \"$(echo "${GOVC_DATASTORE}" | rev | cut -d '/' -f 1 | rev)\""
        echo "        network = \"${GOVC_NETWORK}\""
        echo "        distributed_virtual_switch_uuid = \"${DVS_UUID}\""
      } >> "${FAILURE_DOMAIN_PATH}"

      FAILURE_DOMAIN_OUT=$(echo "$FAILURE_DOMAIN_OUT" | jq --compact-output -r '. += [{"server":"'"${GOVC_URL}"'","datacenter":"'"${GOVC_DATACENTER}"'","cluster":"'"${CLUSTER}"'","datastore":"'"${datastoreName}"'","network":"'"${GOVC_NETWORK}"'","distributed_virtual_switch_uuid":"'"$DVS_UUID"'"}]')
    }

    for LEASE in "${SHARED_DIR}"/LEASE*; do
      if [[ $LEASE =~ "single" ]]; then
        continue
      fi

      echo "checking lease ${LEASE} for failure domains"

      # A lease can cover multiple pools (POOL_COUNT path); every pool becomes
      # its own failure domain.  Leases without poolInfo (legacy single-pool
      # leases) fall back to the top-level status fields.
      pool_info_count=$(jq -r '.status.poolInfo | length' "${LEASE}")
      if [[ "${pool_info_count}" != "null" && "${pool_info_count}" -gt 0 ]]; then
        for ((pool_idx = 0; pool_idx < pool_info_count; pool_idx++)); do
          pool_name=$(jq -r ".status.poolInfo[${pool_idx}].name" "${LEASE}")
          echo "processing pool ${pool_name}"

          server=$(jq -r ".status.poolInfo[${pool_idx}].server" "${LEASE}")
          echo "server is ${server}"

          jq -r ".status.envVarsMap.\"${pool_name}\"" "${LEASE}" > /tmp/envvars

          # shellcheck source=/dev/null
          source /tmp/envvars

          CLUSTER=$(jq -r ".status.poolInfo[${pool_idx}].topology.computeCluster" "${LEASE}" | cut -d '/' -f 4)

          append_failure_domain "${CLUSTER}"
        done
      else
        server=$(jq -r .status.server "$LEASE")
        echo "server is ${server}"

        jq -r .status.envVars "${LEASE}" > /tmp/envvars

        # shellcheck source=/dev/null
        source /tmp/envvars

        CLUSTER=$(jq -r .status.topology.computeCluster "${LEASE}" | cut -d '/' -f 4)

        append_failure_domain "${CLUSTER}"
      fi
    done
    echo "    }" >> ${FAILURE_DOMAIN_PATH}
    echo "]" >> ${FAILURE_DOMAIN_PATH}

    echo "${FAILURE_DOMAIN_OUT}" | jq . > "${FAILURE_DOMAIN_JSON}"
    cat "${FAILURE_DOMAIN_JSON}"
    echo "-getFailureDomainsWithDSwitch"
}

declare vsphere_url
declare GOVC_URL
declare GOVC_DATACENTER
declare GOVC_DATASTORE
declare GOVC_NETWORK
declare gateway
declare vsphere_portgroup
declare vsphere_datastore
declare vsphere_datacenter
declare vsphere_cluster
declare GOVC_USERNAME
declare GOVC_PASSWORD
declare GOVC_TLS_CA_CERTS

# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

openshift_install_path="/var/lib/openshift-install"

start_master_num=4
end_master_num=$((start_master_num + CONTROL_PLANE_REPLICAS - 1))

start_worker_num=$((end_master_num + 1))
end_worker_num=$((start_worker_num + COMPUTE_NODE_REPLICAS - 1))

NETWORK_CONFIG=${SHARED_DIR}/NETWORK_single.json

# We expect this to have the correct number of addresses.  If we are short, we need to exit here with meaningful message.
if jq -e --argjson IPS "$((end_worker_num + 1))" '.spec.ipAddresses | length < $IPS' "${NETWORK_CONFIG}"; then
  echo "SUBNETS.JSON does not contain enough addresses. This workflow is expected to be a single-tenant lease. Please check lease / network type."
  cat "${NETWORK_CONFIG}"
  exit 1
fi

gateway=$(jq -r '.spec.gateway' "${NETWORK_CONFIG}")
dns_server=$(jq -r '.spec.nameservers[0]' "${NETWORK_CONFIG}")
netmask=$(jq -r '.spec.netmask' "${NETWORK_CONFIG}")

lb_ip_address=$(jq -r '.spec.ipAddresses[2]' "${NETWORK_CONFIG}")
bootstrap_ip_address=$(jq -r '.spec.ipAddresses[3]' "${NETWORK_CONFIG}")
machine_cidr=$(jq -r '.spec.machineNetworkCidr' "${NETWORK_CONFIG}")

# printf "***** DEBUG dns: %s lb: %s bootstrap: %s cidr: %s ******\n" "$dns_server" "$lb_ip_address" "$bootstrap_ip_address" "$machine_cidr"

control_plane_idx=0
control_plane_addrs=()
control_plane_hostnames=()
for n in $(seq "$start_master_num" "$end_master_num"); do
  control_plane_addrs+=("$(jq -r --argjson N "$n" '.spec.ipAddresses[$N]' "${NETWORK_CONFIG}")")
  control_plane_hostnames+=("control-plane-$((control_plane_idx++))")
done
printf "**** controlplane DEBUG %s ******\n" "${control_plane_addrs[@]}"

printf -v control_plane_ip_addresses "\"%s\"," "${control_plane_addrs[@]}"
control_plane_ip_addresses="[${control_plane_ip_addresses%,}]"


printf "**** DEBUG start_worker_num: %s end_worker_num: %s ******\n" "${start_worker_num}" "${end_worker_num}"

compute_idx=0
compute_addrs=()
compute_hostnames=()
for n in $(seq "$start_worker_num" "$end_worker_num"); do
  compute_addrs+=("$(jq -r --argjson N "$n" '.spec.ipAddresses[$N]' "${NETWORK_CONFIG}")")
  compute_hostnames+=("compute-$((compute_idx++))")
done

printf "**** compute DEBUG %s ******\n" "${compute_addrs[@]}"

printf -v compute_ip_addresses "\"%s\"," "${compute_addrs[@]}"
compute_ip_addresses="[${compute_ip_addresses%,}]"

# First one for api, second for apps.
echo "${lb_ip_address}" >>"${SHARED_DIR}"/vips.txt
echo "${lb_ip_address}" >>"${SHARED_DIR}"/vips.txt

export HOME=/tmp
# Injected via the release:latest dependency, which upgrade jobs redirect to
# release:initial so the baseline is installed rather than the upgrade target.
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}

echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create basedomain.txt
echo "vmc-ci.devcluster.openshift.com" >"${SHARED_DIR}"/basedomain.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

# Create clustername.txt
echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

# Create clusterdomain.txt
echo "${cluster_name}.${base_domain}" >"${SHARED_DIR}"/clusterdomain.txt
cluster_domain=$(<"${SHARED_DIR}"/clusterdomain.txt)

ssh_pub_key_path="${CLUSTER_PROFILE_DIR}/ssh-publickey"
install_config="${SHARED_DIR}/install-config.yaml"

legacy_installer_json="${openshift_install_path}/rhcos.json"
fcos_json_file="${openshift_install_path}/fcos.json"

if [[ -f "$fcos_json_file" ]]; then
  legacy_installer_json=$fcos_json_file
fi

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
else
  export INSTALLER_BINARY="openshift-install"
fi

# Ensure the installer binary matches the release payload being installed.
# Opt-in via ALIGN_INSTALLER_TO_PAYLOAD: only jobs that redirect the install
# payload away from the installer image's stream (e.g. upgrade jobs installing
# the previous minor) want this. The image's upi-installer binary may be newer
# than the payload, and a newer installer can render bootstrap assets
# incompatible with the payload's CVO (observed:
# "unknown flag: --cluster-version-manifest-path" from cvo-render). When the
# X.Y versions differ, extract the payload's own installer so the bootimage
# matches. If the payload version cannot be determined or extraction fails,
# warn and keep the image's installer.
if [[ "${ALIGN_INSTALLER_TO_PAYLOAD:-false}" == "true" && -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  # Build-farm release images (registry.build*.ci.openshift.org) need CI
  # registry credentials on top of the cluster-profile pull secret. Fail fast
  # on credential setup: this script runs with errexit disabled here, and an
  # opted-in job that cannot resolve its payload should stop now rather than
  # keep a mismatched installer and time out at bootstrap.
  ALIGN_PULL_SECRET="${SHARED_DIR}/pull-secret-with-ci"
  if [[ ! -s "${ALIGN_PULL_SECRET}" ]]; then
    ALIGN_PULL_SECRET="/tmp/pull-secret-with-ci"
    if ! cp -f "${CLUSTER_PROFILE_DIR}/pull-secret" "${ALIGN_PULL_SECRET}"; then
      echo "ERROR: failed to copy the cluster-profile pull secret for installer alignment" 1>&2
      exit 1
    fi
    if [[ "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%%/*}" != "quay.io" ]]; then
      if ! KUBECONFIG="" oc registry login --to "${ALIGN_PULL_SECRET}"; then
        echo "ERROR: failed to log in to the CI registry for installer alignment of ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" 1>&2
        exit 1
      fi
    fi
  fi
  # Match the executable basename: the version output prints the binary as
  # invoked ("openshift-install" from PATH, "/tmp/openshift-install" when
  # extracted from a custom payload).
  INSTALLER_VERSION="$(${INSTALLER_BINARY} version | awk '{sub(/^.*\//, "", $1); if (!found && $1 == "openshift-install") {print $2; found=1}}')"
  # The image's upi-installer reports "v1.4.22-ec5..." (installer repo EC
  # build); a payload-extracted installer reports the payload version
  # "4.21.40...". Normalize both to X.Y.
  if [[ "${INSTALLER_VERSION}" == v1.* ]]; then
    INSTALLER_XY="$(echo "${INSTALLER_VERSION}" | cut -d. -f2,3 | cut -d- -f1)"
  else
    INSTALLER_XY="$(echo "${INSTALLER_VERSION}" | cut -d. -f1,2 | cut -d- -f1)"
  fi
  PAYLOAD_XY="$(oc adm release info -a "${ALIGN_PULL_SECRET}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}' 2>/dev/null || echo '')"
  PAYLOAD_XY="$(echo "${PAYLOAD_XY}" | cut -d. -f1,2)"
  if [[ -z "${PAYLOAD_XY}" ]]; then
    echo "WARNING: unable to determine payload version from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}; keeping the image's installer (${INSTALLER_XY})" 1>&2
  elif [[ "${INSTALLER_XY}" != "${PAYLOAD_XY}" ]]; then
    echo "Installer is ${INSTALLER_XY} but the install payload is ${PAYLOAD_XY}; extracting the payload's installer so the bootimage matches"
    # Extract to a fresh directory so a failed extraction cannot leave a
    # truncated binary at the path the custom-payload flow may already be
    # using; only switch INSTALLER_BINARY after a successful extraction.
    if ! oc adm release extract -a "${ALIGN_PULL_SECRET}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
      --command=openshift-install --to="/tmp/align-installer"; then
      echo "WARNING: failed to extract installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}; keeping the image's installer (${INSTALLER_XY})" 1>&2
    else
      chmod +x /tmp/align-installer/openshift-install
      export INSTALLER_BINARY="/tmp/align-installer/openshift-install"
    fi
  fi
fi

echo "=============== openshift-install version =============="
${INSTALLER_BINARY} version

# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if ${INSTALLER_BINARY} coreos print-stream-json 2>/tmp/err.txt >${SHARED_DIR}/coreos.json; then
  echo "Using stream metadata"
  ova_url=$(jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' < "${SHARED_DIR}"/coreos.json)
else
  if ! grep -qF 'unknown command \"coreos\"' /tmp/err.txt; then
    echo "Unhandled error from openshift-install" 1>&2
    cat /tmp/err.txt
    exit 1
  fi
  legacy_installer_json=/var/lib/openshift-install/rhcos.json
  echo "Falling back to parsing ${legacy_installer_json}"
  ova_url="$(jq -r '.baseURI + .images["vmware"].path' ${legacy_installer_json})"
fi
rm -f /tmp/err.txt

echo "${ova_url}" >"${SHARED_DIR}"/ova_url.txt
ova_url=$(<"${SHARED_DIR}"/ova_url.txt)

vm_template="${ova_url##*/}"

# select a hardware version for testing
vsphere_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $1}')
vsphere_minor_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $3}')

hw_versions=(15 17 18 19)
if [[ ${vsphere_version} -eq 8 ]]; then
    hw_versions=(20)
  if [[ ${vsphere_minor_version} -ge 2 ]]; then
    hw_versions=(20 21)
  fi
fi

hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % hw_available_versions))
target_hw_version=${hw_versions[$selected_hw_version_index]}
echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"
vm_template=${vm_template}-hw${target_hw_version}

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >> "${SHARED_DIR}"/vsphere_context.sh

# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

echo "$(date -u --rfc-3339=seconds) - Extend install-config.yaml ..."

# If platform none is present in the install-config, extension is skipped.
declare platform_none="none: {}"
platform_required=true
if grep -F "${platform_none}" "${install_config}"; then
  echo "platform none present, install-config will not be extended"
  platform_required=false
fi

# Create DNS files for nodes
if command -v pwsh &> /dev/null
then
  ROUTE53_CREATE_JSON='{"Comment": "Create public OpenShift DNS records for Nodes of VSphere UPI CI install", "Changes": []}'
  ROUTE53_DELETE_JSON='{"Comment": "Delete public OpenShift DNS records for Nodes of VSphere UPI CI install", "Changes": []}'

  # shellcheck disable=SC2016
  DNS_RECORD='{
  "Action": "${ACTION}",
  "ResourceRecordSet": {
    "Name": "${CLUSTER_NAME}-${VM_NAME}.${CLUSTER_DOMAIN}.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [{"Value": "${IP_ADDRESS}"}]
    }
  }'

  # Generate control plane DNS entries
  for (( node=0; node < CONTROL_PLANE_REPLICAS; node++)); do
    echo "Creating DNS entry for ${control_plane_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${control_plane_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${control_plane_addrs[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done
  # Generate compute DNS entries
  for (( node=0; node < COMPUTE_NODE_REPLICAS; node++)); do
    echo "Creating DNS entry for ${compute_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${compute_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${compute_addrs[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done

  echo "Creating json to create Node DNS records..."
  echo "${ROUTE53_CREATE_JSON}" > "${SHARED_DIR}"/dns-nodes-create.json

  echo "Creating json file to delete Node DNS records..."
  echo "${ROUTE53_DELETE_JSON}" > "${SHARED_DIR}"/dns-nodes-delete.json
fi

VERSION=$(oc adm release info "${TESTING_RELEASE_IMAGE}" --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)

set -o errexit

MAJOR_VERSION=1000
Z_VERSION=0
OCP_VERSION=100000

if [ ! -z "${VERSION}" ]; then
  MAJOR_VERSION=$(echo "${VERSION}" | cut -d'.' -f1)
  Z_VERSION=$(echo "${VERSION}" | cut -d'.' -f2)
  OCP_VERSION=$((MAJOR_VERSION * 100 + Z_VERSION))
  echo "$(date -u --rfc-3339=seconds) - determined version is ${MAJOR_VERSION}.${Z_VERSION}"
else
  echo "$(date -u --rfc-3339=seconds) - unable to determine version stream, assuming this is master"
fi

${platform_required} && cat >>"${install_config}" <<EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: ${CONTROL_PLANE_REPLICAS}

compute:
- name: "worker"
  replicas: ${COMPUTE_NODE_REPLICAS}

networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

PULL_THROUGH_CACHE_DISABLE="/var/run/vault/vsphere-ibmcloud-config/pull-through-cache-disable"
CACHE_FORCE_DISABLE="false"
if [ -f "${PULL_THROUGH_CACHE_DISABLE}" ]; then
  CACHE_FORCE_DISABLE=$(cat ${PULL_THROUGH_CACHE_DISABLE})
fi

if [ ${CACHE_FORCE_DISABLE} == "false" ]; then
  if [ ${PULL_THROUGH_CACHE} == "enabled" ]; then
    echo "$(date -u --rfc-3339=seconds) - pull-through cache enabled for job"
    PULL_THROUGH_CACHE_CREDS="/var/run/vault/vsphere-ibmcloud-config/pull-through-cache-secret"
    PULL_THROUGH_CACHE_CONFIG="/var/run/vault/vsphere-ibmcloud-config/pull-through-cache-config"
    PULL_SECRET="/var/run/secrets/ci.openshift.io/cluster-profile/pull-secret"
    TMP_INSTALL_CONFIG="/tmp/tmp-install-config.yaml"
    if [ -f ${PULL_THROUGH_CACHE_CREDS} ]; then
      echo "$(date -u --rfc-3339=seconds) - pull-through cache credentials found. updating pullSecret"
      cat ${install_config} | sed '/pullSecret/d' >${TMP_INSTALL_CONFIG}2
      cat ${TMP_INSTALL_CONFIG}2 | sed '/\"auths\"/d' >${TMP_INSTALL_CONFIG}
      jq -cs '.[0] * .[1]' ${PULL_SECRET} ${PULL_THROUGH_CACHE_CREDS} >/tmp/ps-combined.json
      echo -e "\npullSecret: '""$(cat /tmp/ps-combined.json)""'" >>${TMP_INSTALL_CONFIG}
      cat ${TMP_INSTALL_CONFIG} >${install_config}
    else
      echo "$(date -u --rfc-3339=seconds) - pull-through cache credentials not found. not updating pullSecret"
    fi
    if [ -f ${PULL_THROUGH_CACHE_CONFIG} ]; then
      echo "$(date -u --rfc-3339=seconds) - pull-through cache configuration found. updating install-config"
      if [ "${OCP_VERSION}" -lt 414 ]; then
        echo "$(date -u --rfc-3339=seconds) - detected OCP version < 4.14.  converting imageDigestSources to imageContentSources for backwards compatability."
        cat ${PULL_THROUGH_CACHE_CONFIG} | sed 's/imageDigestSources/imageContentSources/g' >>${install_config}
      else
        cat ${PULL_THROUGH_CACHE_CONFIG} >>${install_config}
      fi
    else
      echo "$(date -u --rfc-3339=seconds) - pull-through cache configuration not found. not updating install-config"
    fi
  fi
else
  echo "$(date -u --rfc-3339=seconds) - pull-through cache force disabled"
fi

if [ "${OCP_VERSION}" -lt 413 ]; then
  #vsphere_cluster_name=$(echo "${vsphere_cluster}" | rev | cut -d '/' -f 1 | rev)
  #datastore_name=$(echo "${vsphere_datastore}" | rev | cut -d '/' -f 1 | rev)
${platform_required} && cat >>"${install_config}" <<EOF
platform:
  vsphere:
    vcenter: "${vsphere_url}"
    datacenter: "${vsphere_datacenter}"
    defaultDatastore: "$(basename "${vsphere_datastore}")"
    cluster: "$(basename "${vsphere_cluster}")"
    network: "${vsphere_portgroup}"
    password: "${GOVC_PASSWORD}"
    username: "${GOVC_USERNAME}"
EOF
else
${platform_required} && cat >>"${install_config}" <<EOF
platform:
  vsphere:
$(cat "$SHARED_DIR"/platform.yaml)
EOF
fi

#set machine cidr if proxy is enabled
if grep 'httpProxy' "${install_config}"; then
  cat >>"${install_config}" <<EOF
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF
fi

echo "$(date -u --rfc-3339=seconds) - ***** DEBUG ***** DNS: ${dns_server}"

echo "$(date -u --rfc-3339=seconds) - Getting failure domains ..."
getFailureDomainsWithDSwitch

echo "$(date -u --rfc-3339=seconds) - Create terraform.tfvars ..."
cat >"${SHARED_DIR}/terraform.tfvars" <<-EOF
machine_cidr = "${machine_cidr}"
vm_template = "${vm_template}"
vsphere_server = "${vsphere_url}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_datacenter = "${vsphere_datacenter}"
vsphere_datastore = "${vsphere_datastore}"
ipam = "ipam.vmc.ci.openshift.org"

cluster_id = "${cluster_name}"
vm_network = "${vsphere_portgroup}"

base_domain = "${base_domain}"
cluster_domain = "${cluster_domain}"
ssh_public_key_path = "${ssh_pub_key_path}"
compute_memory = "16384"
compute_num_cpus = "4"
vm_dns_addresses = ["${dns_server}"]
bootstrap_ip_address = "${bootstrap_ip_address}"
lb_ip_address = "${lb_ip_address}"

compute_ip_addresses = ${compute_ip_addresses}
control_plane_ip_addresses = ${control_plane_ip_addresses}
control_plane_count = ${CONTROL_PLANE_REPLICAS}
compute_count = ${COMPUTE_NODE_REPLICAS}
failure_domains = $(cat $FAILURE_DOMAIN_PATH)
EOF

VCENTERS_JSON=$(cat "${install_config}" | yq-v4 -o json | jq -c '.platform.vsphere.vcenters')

if [[ "$VCENTERS_JSON" != "null" ]]; then
    echo "Generating vcenters for variables.ps1"
    VCENTERS_JSON=$'$vcenters = \''${VCENTERS_JSON}$'\''
else
    echo "vCenters definition not found in install-config.  Skipping setting for variables.ps1"
    VCENTERS_JSON=""
fi

SPEC_CONFIG="/var/run/vault/vsphere-ibmcloud-config/vm-specs.json"

# Older versions of UPI image do not support changing coresPerSocket.  It is hard coded to 4 for CPS.  In these environments, We'll default to 4 cores.
control_plane_cpu=$(jq -r '.spec.controlplane.cpus' ${SPEC_CONFIG})
compute_cpu=$(jq -r '.spec.compute.cpus' ${SPEC_CONFIG})
if [ "${OCP_VERSION}" -lt 420 ]; then
    echo "$(date -u --rfc-3339=seconds) - Detected legacy jobs.  Configuring CPU counts to 4 ..."
    control_plane_cpu=4
    compute_cpu=4
fi

echo "$(date -u --rfc-3339=seconds) - Create variables.ps1 ..."
cat >"${SHARED_DIR}/variables.ps1" <<-EOF
\$clustername = "${cluster_name}"
\$basedomain = "${base_domain}"
\$clusterdomain = "${cluster_domain}"
\$sshkeypath = "${ssh_pub_key_path}"

\$machine_cidr = "${machine_cidr}"

\$vm_template = "$(basename "${vm_template}")"
\$vcenter = "${vsphere_url}"
\$portgroup = "$(basename "${vsphere_portgroup}")"
\$datastore = "$(basename "${vsphere_datastore}")"
\$datacenter = "$(basename "${vsphere_datacenter}")"
\$cluster = "$(basename "${vsphere_cluster}")"
\$vcentercredpath = "secrets/vcenter-creds.xml"
\$storagepolicy = ""
\$secureboot = \$false

\$ipam = "ipam.vmc.ci.openshift.org"

\$dns = "${dns_server}"
\$gateway = "${gateway}"
\$netmask ="${netmask}"

\$bootstrap_ip_address = "${bootstrap_ip_address}"

\$lb_memory =  $(jq -r '.spec.lb.memoryMB' ${SPEC_CONFIG})
\$lb_num_cpus = $(jq -r '.spec.lb.cpus' ${SPEC_CONFIG})
\$lb_cores_per_socket = $(jq -r '.spec.lb.coresPerSocket' ${SPEC_CONFIG})
\$lb_ip_address = "${lb_ip_address}"

\$control_plane_memory =  $(jq -r '.spec.controlplane.memoryMB' ${SPEC_CONFIG})
\$control_plane_num_cpus = ${control_plane_cpu}
\$control_plane_cores_per_socket = $(jq -r '.spec.controlplane.coresPerSocket' ${SPEC_CONFIG})
\$control_plane_count = ${CONTROL_PLANE_REPLICAS}
\$control_plane_ip_addresses = $(echo "${control_plane_ip_addresses}" | tr -d '[]')
\$control_plane_hostnames = $(printf "\"%s\"," "${control_plane_hostnames[@]}" | sed 's/,$//')

\$compute_memory =  $(jq -r '.spec.compute.memoryMB' ${SPEC_CONFIG})
\$compute_num_cpus = ${compute_cpu}
\$compute_cores_per_socket = $(jq -r '.spec.compute.coresPerSocket' ${SPEC_CONFIG})
\$compute_count = ${COMPUTE_NODE_REPLICAS}
\$compute_ip_addresses = $(echo "${compute_ip_addresses}" | tr -d '[]')
\$compute_hostnames = $(printf "\"%s\"," "${compute_hostnames[@]}" | sed 's/,$//')

\$failure_domains = @"
$(cat ${FAILURE_DOMAIN_JSON})
"@

$(echo ${VCENTERS_JSON})
EOF

echo "$(date -u --rfc-3339=seconds) - Create secrets.auto.tfvars..."
cat >"${SHARED_DIR}/secrets.auto.tfvars" <<-EOF
vsphere_password="${GOVC_PASSWORD}"
vsphere_user="${GOVC_USERNAME}"
ipam_token=""
EOF

if command -v pwsh &> /dev/null
then
  echo "Creating powercli credentials file"
  pwsh -command "\$User='${GOVC_USERNAME}';\$Password=ConvertTo-SecureString -String '${GOVC_PASSWORD}' -AsPlainText -Force;\$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList \$User, \$Password;\$Credential | Export-Clixml ${SHARED_DIR}/vcenter-creds.xml"
fi

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
  "${SHARED_DIR}/install-config.yaml"

date +%s >"${SHARED_DIR}/TEST_TIME_INSTALL_START"

### Create manifests
echo "Creating manifests..."
${INSTALLER_BINARY} --dir="${dir}" create manifests &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit "$ret"
fi

JOURNAL_LOGGING_ENABLED="$(cat /var/run/vault/vsphere-ibmcloud-config/journal-logging-enabled)"
JOURNAL_LOGGING_ENABLED="${JOURNAL_LOGGING_ENABLED,,}"

if [[ "${JOURNAL_LOGGING_ENABLED}" == "true" ]]; then
  echo "Enabling journal forwarding machine config manifests..."
  cat >"manifests/99_journal_forward_machine_config_master.yaml" <<-EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: journal-forwarder-master
spec:
  config:
    storage:
      files:
      - contents:
          source: data:;base64,IyEvYmluL3NoCgppZiBbICIkIyIgLWd0IDAgXTsgdGhlbgogICAgIyBXZSBoYXZlIGNvbW1hbmQgbGluZSBhcmd1bWVudHMuCiAgICAjIE91dHB1dCB0aGVtIHdpdGggbmV3bGluZXMgaW4tYmV0d2Vlbi4KICAgIHByaW50ZiAnJXNcbicgIiRAIgplbHNlCiAgICAjIE5vIGNvbW1hbmQgbGluZSBhcmd1bWVudHMuCiAgICAjIEp1c3QgcGFzcyBzdGRpbiBvbi4KICAgIGNhdApmaSB8CndoaWxlIElGUz0gcmVhZCAtciBzdHJpbmc7IGRvCiAgICBjdXJsIC1YIFBPU1QgXAogICAgIC1IICJDb250ZW50LVR5cGU6IHRleHQvcGxhaW4iIFwKICAgICAtSCAibm9kZS1pZDogJChob3N0bmFtZSkiIFwKICAgICAtZCAiJHN0cmluZyIgXAogICAgIGh0dHA6Ly9sb2ctZ2F0aGVyLnZtYy5jaS5vcGVuc2hpZnQub3JnOjgwMDAgPiAvZGV2L251bGwgMj4mMQpkb25l
        mode: 0777
        overwrite: true
        path: /var/journal-gather-forwarder/forward.sh

    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: journal-forwarder.service
          enabled: true
          contents: |
            [Unit]
            Description=Forwards the journal to log server
            After=network.target
            Wants=network-online.target
            [Service]
            Restart=always
            Type=simple
            RestartSec=30
            ExecStart=/bin/sh -c "stdbuf -oL journalctl -f | /var/journal-gather-forwarder/forward.sh"
            Environment=
            [Install]
            WantedBy=multi-user.target
EOF

  cat >"manifests/99_journal_forward_machine_config_compute.yaml" <<-EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: journal-forwarder-compute
spec:
  config:
    storage:
      files:
      - contents:
          source: data:;base64,IyEvYmluL3NoCgppZiBbICIkIyIgLWd0IDAgXTsgdGhlbgogICAgIyBXZSBoYXZlIGNvbW1hbmQgbGluZSBhcmd1bWVudHMuCiAgICAjIE91dHB1dCB0aGVtIHdpdGggbmV3bGluZXMgaW4tYmV0d2Vlbi4KICAgIHByaW50ZiAnJXNcbicgIiRAIgplbHNlCiAgICAjIE5vIGNvbW1hbmQgbGluZSBhcmd1bWVudHMuCiAgICAjIEp1c3QgcGFzcyBzdGRpbiBvbi4KICAgIGNhdApmaSB8CndoaWxlIElGUz0gcmVhZCAtciBzdHJpbmc7IGRvCiAgICBjdXJsIC1YIFBPU1QgXAogICAgIC1IICJDb250ZW50LVR5cGU6IHRleHQvcGxhaW4iIFwKICAgICAtSCAibm9kZS1pZDogJChob3N0bmFtZSkiIFwKICAgICAtZCAiJHN0cmluZyIgXAogICAgIGh0dHA6Ly9sb2ctZ2F0aGVyLnZtYy5jaS5vcGVuc2hpZnQub3JnOjgwMDAgPiAvZGV2L251bGwgMj4mMQpkb25l
        mode: 0777
        overwrite: true
        path: /var/journal-gather-forwarder/forward.sh

    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: journal-forwarder.service
          enabled: true
          contents: |
            [Unit]
            Description=Forwards the journal to log server
            After=network.target
            Wants=network-online.target
            [Service]
            Restart=always
            Type=simple
            RestartSec=30
            ExecStart=/bin/sh -c "stdbuf -oL journalctl -f | /var/journal-gather-forwarder/forward.sh"
            Environment=
            [Install]
            WantedBy=multi-user.target
EOF
fi

# remove channel from CVO
sed -i '/^  channel:/d' "manifests/cvo-overrides.yaml"

### Remove control plane machines
echo "Removing control plane machines..."
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml

### Remove compute machinesets (optional)
echo "Removing compute machinesets..."
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

### Remove control-plane machinesets
echo "Removing control-plane machineset..."
rm -f openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml

### Make control-plane nodes unschedulable
echo "Making control-plane nodes unschedulable..."
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" manifests/cluster-scheduler-02-config.yml

### Check hybrid network manifest
if test -f "${SHARED_DIR}/manifest_cluster-network-03-config.yml"; then
  echo "Applying hybrid network manifest..."
  cp "${SHARED_DIR}/manifest_cluster-network-03-config.yml" manifests/cluster-network-03-config.yml
fi

# Simulate a cluster installed without vSphere failure domain information (e.g.
# pre-4.13 or UPI installs that never populate it). vcenters/failureDomains are
# only present under spec.platformSpec.vsphere (VSpherePlatformStatus carries
# neither field), and the installer never backfills this on upgrade, so deleting
# it here from the pre-bootstrap manifest reproduces that persistent state
# without fighting any later immutability/admission checks on a live cluster.
#
# Before deleting it, compute the legacy-INI form of
# openshift-config/cloud-provider-config from the installer-rendered YAML,
# using the exact server/datacenter/datastore/folder values the installer
# resolved for this install's sole failure domain. No installer version in
# active use renders cloud-provider-config as INI anymore -- a fresh install
# always emits YAML there, regardless of install-config schema -- so
# stripping alone produces a config-format/Infra-CR combination (new-format
# config + legacy-shaped Infra) that cannot occur on a real cluster, and
# leaves vmware-vsphere-csi-driver-operator with no source of
# datastore/topology data at all: a storage ClusterOperator that never
# leaves Degraded, which keeps the install itself from ever completing
# (SPLAT-3028). Real UPI/pre-4.13 clusters have always carried this data in
# the INI [Workspace] section instead; a real 4.12-origin cluster upgraded
# through day-2 multi-vCenter GA confirms cloud-provider-config stays INI,
# untouched since original install, and that storage stays Available in
# that exact state.
#
# The computed INI is staged to a file outside manifests/, not written
# straight into cloud-provider-config.yaml, because cluster-config-operator's
# bootstrap-time render (invoked from bootkube.sh's "config-bootstrap" stage)
# has no vSphere-specific transformer and just copies that ConfigMap
# byte-for-byte into ControllerConfig.Spec.CloudProviderConfig, and from
# there into /etc/kubernetes/cloud.conf on every node. The in-cluster
# machine-config-controller regenerates that same field moments later from
# cluster-cloud-controller-manager-operator's CCCMO-normalized (YAML) copy of
# the same ConfigMap, so if the file were already legacy INI at render time,
# the two renders would disagree byte-for-byte and trip MCD's one-time
# "bootstrap generated MC vs in-cluster generated MC" mismatch check,
# permanently degrading the machine-config ClusterOperator. The staged
# content is applied later, after `create ignition-configs` and
# cluster-config-operator's render have both consumed the installer's
# native (modern) YAML -- see the injection below, right before this
# script hands the ignition files off to the VM-provisioning step.
if [[ "${STRIP_VSPHERE_FAILURE_DOMAINS:-}" == "true" ]]; then
  echo "$(date -u --rfc-3339=seconds) - staging legacy-INI cloud-provider-config for later injection (SPLAT-3028)"
  infra_manifest="manifests/cluster-infrastructure-02-config.yml"
  ccm_manifest="manifests/cloud-provider-config.yaml"
  staged_ccm_manifest="vsphere-legacy-cloud-provider-config.yaml"

  # infraID comes from the Infrastructure manifest's own
  # status.infrastructureName rather than metadata.json: metadata.json is not
  # written to disk until `create ignition-configs` runs, so reading it here
  # (right after `create manifests`) would either read a stale file or,
  # under `set -o errexit`, silently kill the whole script when it doesn't
  # exist yet.
  vsphere_fd_server=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.vcenters[0].server")
  vsphere_fd_datacenter=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.failureDomains[0].topology.datacenter")
  vsphere_fd_datastore_path=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.failureDomains[0].topology.datastore")
  vsphere_fd_folder=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.failureDomains[0].topology.folder")
  vsphere_fd_resource_pool=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.failureDomains[0].topology.resourcePool")
  vsphere_fd_port=$(yq-go r "${infra_manifest}" "spec.platformSpec.vsphere.vcenters[0].port")
  vsphere_infra_id=$(yq-go r "${infra_manifest}" "status.infrastructureName")
  for v in vsphere_fd_server vsphere_fd_datacenter vsphere_fd_datastore_path vsphere_fd_folder vsphere_fd_resource_pool vsphere_fd_port vsphere_infra_id; do
    [[ "${!v}" == "null" ]] && eval "${v}=\"\""
  done
  vsphere_fd_datastore="${vsphere_fd_datastore_path##*/}"
  [[ "${vsphere_fd_port}" == "0" ]] && vsphere_fd_port=""

  if [[ -z "${vsphere_fd_server}" || -z "${vsphere_fd_datacenter}" || -z "${vsphere_fd_datastore}" ]]; then
    echo "ERROR: could not read vCenter server/datacenter/datastore from ${infra_manifest}; cannot build a legacy cloud-provider-config" >&2
    exit 1
  fi

  if [[ -z "${vsphere_fd_folder}" ]]; then
    if [[ -n "${vsphere_infra_id}" ]]; then
      vsphere_fd_folder="/${vsphere_fd_datacenter}/vm/${vsphere_infra_id}"
    else
      echo "WARNING: no topology.folder resolved and no status.infrastructureName available; omitting 'folder' from the legacy [Workspace] section" >&2
    fi
  fi

  vsphere_cm_name=$(yq-go r "${ccm_manifest}" "metadata.name")
  vsphere_cm_namespace=$(yq-go r "${ccm_manifest}" "metadata.namespace")

  vsphere_port_line="" vsphere_folder_line="" vsphere_resource_pool_line=""
  [[ -n "${vsphere_fd_port}" ]] && vsphere_port_line="    port = \"${vsphere_fd_port}\""$'\n'
  [[ -n "${vsphere_fd_folder}" ]] && vsphere_folder_line="    folder = \"${vsphere_fd_folder}\""
  [[ -n "${vsphere_fd_resource_pool}" ]] && vsphere_resource_pool_line="    resourcepool-path = \"${vsphere_fd_resource_pool}\""

  # Mirrors openshift-installer's own CloudProviderConfigIni() in
  # pkg/asset/manifests/vsphere/cloudproviderconfig.go -- dead code there
  # (no caller in the installer outside its own tests, since no installer
  # version in active use ever selects this format for a fresh install) but
  # still the product's canonical legacy-INI shape, including its
  # infraID-based default folder, so what this job manufactures matches as
  # closely as possible what a real pre-4.13/UPI install would have produced.
  #
  # Written to staged_ccm_manifest, not ccm_manifest: see the comment above
  # for why this must not land in manifests/ until after the bootstrap-time
  # swap below.
  cat > "${staged_ccm_manifest}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${vsphere_cm_name}
  namespace: ${vsphere_cm_namespace}
data:
  config: |
    [Global]
    secret-name = "vsphere-creds"
    secret-namespace = "kube-system"
    insecure-flag = "1"

    [VirtualCenter "${vsphere_fd_server}"]
${vsphere_port_line}    datacenters = "${vsphere_fd_datacenter}"

    [Workspace]
    server = "${vsphere_fd_server}"
    datacenter = "${vsphere_fd_datacenter}"
    default-datastore = "${vsphere_fd_datastore}"
${vsphere_folder_line}
${vsphere_resource_pool_line}
EOF

  echo "$(date -u --rfc-3339=seconds) - stripping vcenters/failureDomains from the Infrastructure manifest"
  yq-go d -i "manifests/cluster-infrastructure-02-config.yml" "spec.platformSpec.vsphere.vcenters"
  yq-go d -i "manifests/cluster-infrastructure-02-config.yml" "spec.platformSpec.vsphere.failureDomains"
fi

### Create Ignition configs
echo "Creating Ignition configs..."
${INSTALLER_BINARY} --dir="${dir}" create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

date +%s >"${SHARED_DIR}/TEST_TIME_INSTALL_END"

cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

# Swap cloud-provider-config to the legacy INI form inside bootstrap.ign, now
# that cluster-config-operator's bootstrap-time render (triggered by the
# `create ignition-configs` above, via bootkube.sh's "config-bootstrap"
# stage) has already consumed the installer's native (modern) YAML left in
# place by the staging above. cluster-config-operator's render has no
# vSphere-specific transformer, so whatever is in that ConfigMap when it
# runs is copied byte-for-byte into ControllerConfig.Spec.CloudProviderConfig;
# letting it see the installer's own YAML there is a no-op once
# vcenters/failureDomains are empty (both that render and the in-cluster
# cluster-cloud-controller-manager-operator transform converge on the same
# content for that case), so bootstrap and in-cluster agree (SPLAT-3028).
#
# The merged systemd unit below waits for /opt/openshift/config-bootstrap.done:
# the marker for the very stage whose cluster-config-operator render reads
# this ConfigMap, and several bootkube stages before "cb-bootstrap", the
# generic manifest-apply step that actually creates the live ConfigMap object.
# It must not gate on a later marker: observed in a real bootstrap,
# "cco-bootstrap" completes and "cb-bootstrap" starts within the same second,
# so gating there let the swap land ~4s after cluster-bootstrap had begun
# reading manifests/ -- harmless, since cluster-bootstrap retries and the file
# parses, but a race with no margin.
if [[ "${STRIP_VSPHERE_FAILURE_DOMAINS:-}" == "true" ]]; then
  echo "$(date -u --rfc-3339=seconds) - injecting the legacy cloud-provider-config swap into bootstrap.ign (SPLAT-3028)"

  if [[ ! -s "${staged_ccm_manifest}" ]]; then
    echo "ERROR: ${staged_ccm_manifest} is missing or empty; the legacy cloud-provider-config staging step above must have failed silently" >&2
    exit 1
  fi

  vsphere_legacy_cc_dir=/tmp/vsphere-legacy-cloud-config
  mkdir -p "${vsphere_legacy_cc_dir}"
  cp "${staged_ccm_manifest}" "${vsphere_legacy_cc_dir}/cloud-provider-config-legacy.yaml"

  cat > "${vsphere_legacy_cc_dir}/swap-cloud-provider-config.sh" << 'SCRIPT_EOF'
#!/bin/bash
set -o nounset
set -o pipefail

marker=/opt/openshift/config-bootstrap.done
target=/opt/openshift/manifests/cloud-provider-config.yaml
source_file=/opt/openshift/cloud-provider-config-legacy.yaml
timeout_seconds=900
elapsed=0

echo "$(date -u --rfc-3339=seconds) - waiting for ${marker} before swapping cloud-provider-config to legacy INI (SPLAT-3028)"
until [[ -f "${marker}" ]]; do
  if (( elapsed >= timeout_seconds )); then
    echo "$(date -u --rfc-3339=seconds) - ERROR: ${marker} did not appear within ${timeout_seconds}s; leaving cloud-provider-config.yaml in its modern (non-legacy) form. The legacy vSphere infra simulation did NOT take effect for cloud-provider-config (SPLAT-3028)." >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

if ! cp "${source_file}" "${target}"; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: failed to overwrite ${target} with ${source_file}" >&2
  exit 1
fi
echo "$(date -u --rfc-3339=seconds) - overwrote ${target} with the legacy INI ConfigMap after a ${elapsed}s wait for ${marker} (SPLAT-3028)"
SCRIPT_EOF

  cat > "${vsphere_legacy_cc_dir}/fcct.yml" << EOF
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: bootstrap_initial.ign
storage:
  files:
    - path: /opt/openshift/cloud-provider-config-legacy.yaml
      mode: 0644
      overwrite: true
      contents:
        local: cloud-provider-config-legacy.yaml
    - path: /usr/local/bin/swap-vsphere-cloud-provider-config.sh
      mode: 0755
      overwrite: true
      contents:
        local: swap-cloud-provider-config.sh
systemd:
  units:
    - name: swap-vsphere-cloud-provider-config.service
      enabled: true
      contents: |
        [Unit]
        Description=Swap cloud-provider-config to the legacy INI form once cluster-config-operator's bootstrap render has consumed the modern YAML (SPLAT-3028)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/swap-vsphere-cloud-provider-config.sh

        [Install]
        WantedBy=multi-user.target
EOF

  cp "${dir}/bootstrap.ign" "${vsphere_legacy_cc_dir}/bootstrap_initial.ign"
  # SSL_CERT_FILE may be set to a vCenter-only CA bundle in this environment
  # (the other vsphere step scripts in this repo unset it for the same
  # reason), which breaks TLS verification of this public mirror's normal
  # certificate. Use the system trust store for this call instead.
  if ! env -u SSL_CERT_FILE curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 \
    "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/butane/latest/butane-amd64" -o /tmp/fcct; then
    echo "ERROR: failed to download butane/fcct for the vsphere legacy cloud-provider-config swap" >&2
    exit 1
  fi
  chmod ug+x /tmp/fcct
  /tmp/fcct --pretty --strict -d "${vsphere_legacy_cc_dir}" "${vsphere_legacy_cc_dir}/fcct.yml" > "${dir}/bootstrap.ign"
fi

cp -t "${SHARED_DIR}" \
  "${dir}/auth/kubeadmin-password" \
  "${dir}/auth/kubeconfig" \
  "${dir}/metadata.json" \
  "${dir}"/*.ign

# Removed tar of openshift state. Not enough room in SHARED_DIR with terraform state

popd
