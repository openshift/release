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
    
    for LEASE in "${SHARED_DIR}"/LEASE*; do      
      if [[ $LEASE =~ "single" ]]; then 
        continue
      fi

      echo "checking lease ${LEASE} for failure domains"

      server=$(jq -r .status.server "$LEASE")

      echo "server is ${server}"

      if [ ${FIRST} == 0 ]; then
          echo "    }," >> ${FAILURE_DOMAIN_PATH}
      fi
      echo "    {" >> ${FAILURE_DOMAIN_PATH}
      FIRST=0

      jq -r .status.envVars "${LEASE}" > /tmp/envvars
      
      # shellcheck source=/dev/null
      source /tmp/envvars

      CLUSTER=$(jq -r .status.topology.computeCluster "${LEASE}" | cut -d '/' -f 4)

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
      
      FAILURE_DOMAIN_OUT=$(echo "$FAILURE_DOMAIN_OUT" | jq --compact-output -r '. += [{"server":"'"${GOVC_URL}"'","datacenter":"'"${GOVC_DATACENTER}"'","cluster":"'"${CLUSTER}"'","datastore":"'"${datastoreName}"'","network":"'"${GOVC_NETWORK}"'","distributed_virtual_switch_uuid":"'"$DVS_UUID"'"}]');
    done
    echo "    }" >> "${FAILURE_DOMAIN_PATH}"  
    echo "]" >> "${FAILURE_DOMAIN_PATH}"

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

dns_server=$(jq -r '.spec.gateway' "${NETWORK_CONFIG}")
gateway=${dns_server}
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
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
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

# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if openshift-install coreos print-stream-json 2>/tmp/err.txt >${SHARED_DIR}/coreos.json; then
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

Z_VERSION=1000

if [ ! -z "${VERSION}" ]; then
  Z_VERSION=$(echo "${VERSION}" | cut -d'.' -f2)
  echo "$(date -u --rfc-3339=seconds) - determined version is 4.${Z_VERSION}"
else
  echo "$(date -u --rfc-3339=seconds) - unable to determine y stream, assuming this is master"
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
      cat ${PULL_THROUGH_CACHE_CONFIG} >>${install_config}
    else
      echo "$(date -u --rfc-3339=seconds) - pull-through cache configuration not found. not updating install-config"
    fi
  fi
else
  echo "$(date -u --rfc-3339=seconds) - pull-through cache force disabled"
fi

if [ "${Z_VERSION}" -lt 13 ]; then
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
    folder: "/${vsphere_datacenter}/vm/${cluster_name}"
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
\$lb_ip_address = "${lb_ip_address}"

\$control_plane_memory = 16384
\$control_plane_num_cpus = 4
\$control_plane_count = ${CONTROL_PLANE_REPLICAS}
\$control_plane_ip_addresses = $(echo "${control_plane_ip_addresses}" | tr -d [])
\$control_plane_hostnames = $(printf "\"%s\"," "${control_plane_hostnames[@]}" | sed 's/,$//')

\$compute_memory = 16384
\$compute_num_cpus = 4
\$compute_count = ${COMPUTE_NODE_REPLICAS}
\$compute_ip_addresses = $(echo "${compute_ip_addresses}" | tr -d [])
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
openshift-install --dir="${dir}" create manifests &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit "$ret"
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

### Create Ignition configs
echo "Creating Ignition configs..."
openshift-install --dir="${dir}" create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

date +%s >"${SHARED_DIR}/TEST_TIME_INSTALL_END"

cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
  "${dir}/auth/kubeadmin-password" \
  "${dir}/auth/kubeconfig" \
  "${dir}/metadata.json" \
  "${dir}"/*.ign

# Removed tar of openshift state. Not enough room in SHARED_DIR with terraform state

popd
