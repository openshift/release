#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

openshift_install_path="/var/lib/openshift-install"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_cluster
declare dns_server
declare vsphere_url
declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup

source "${SHARED_DIR}/vsphere_context.sh"

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

  machine_cidr="192.168.${third_octet}.0/25"
  bootstrap_ip_address="192.168.${third_octet}.3"
  lb_ip_address="192.168.${third_octet}.2"

  read -r compute_ip_addresses <<EOM
["192.168.${third_octet}.7","192.168.${third_octet}.8","192.168.${third_octet}.9"]
EOM

  read -r control_plane_ip_addresses <<EOM
["192.168.${third_octet}.4","192.168.${third_octet}.5","192.168.${third_octet}.6"]
EOM

else

  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  # ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway

  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")


  lb_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[2]' "${SUBNETS_CONFIG}")
  bootstrap_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[3]' "${SUBNETS_CONFIG}")
  machine_cidr=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}")

  tempaddrs=()
  for n in {4..6}; do
    tempaddrs+=("$(jq -r --argjson N $n --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
  done

  printf -v control_plane_ip_addresses "\"%s\"," "${tempaddrs[@]}"
  control_plane_ip_addresses="[${control_plane_ip_addresses%,}]"

  tempaddrs=()
  for n in {7..9}; do
    tempaddrs+=("$(jq -r --argjson N $n --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
  done

  printf -v compute_ip_addresses "\"%s\"," "${tempaddrs[@]}"
  compute_ip_addresses="[${compute_ip_addresses%,}]"

fi

export HOME=/tmp
#export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
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

# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if openshift-install coreos print-stream-json 2>/tmp/err.txt >${SHARED_DIR}/coreos.json; then
  echo "Using stream metadata"
  ova_url=$(jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' <${SHARED_DIR}/coreos.json)
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

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

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

echo "export target_hw_version=${target_hw_version}" >>${SHARED_DIR}/vsphere_context.sh
echo "$(date -u --rfc-3339=seconds) - Extend install-config.yaml ..."

# If platform none is present in the install-config, extension is skipped.
declare platform_none="none: {}"
platform_required=true
if grep -F "${platform_none}" "${install_config}"; then
  echo "platform none present, install-config will not be extended"
  platform_required=false
fi

${platform_required} && cat >>"${install_config}" <<EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
compute:
- name: "worker"
  replicas: 0
platform:
  vsphere:
    vcenter: "${vsphere_url}"
    datacenter: "${vsphere_datacenter}"
    defaultDatastore: "${vsphere_datastore}"
    cluster: "${vsphere_cluster}"
    network: "${vsphere_portgroup}"
    password: "${GOVC_PASSWORD}"
    username: "${GOVC_USERNAME}"
    folder: "/${vsphere_datacenter}/vm/${cluster_name}"
EOF

#set machine cidr if proxy is enabled
if grep 'httpProxy' "${install_config}"; then
  cat >>"${install_config}" <<EOF
networking:
  machineNetwork:
  - cidr: "$machine_cidr"
EOF
fi

echo "$(date -u --rfc-3339=seconds) - Create terraform.tfvars ..."
cat >"${SHARED_DIR}/terraform.tfvars" <<-EOF

machine_cidr = "${machine_cidr}"

vm_template = "${vm_template}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_datacenter = "${vsphere_datacenter}"
vsphere_datastore = "${vsphere_datastore}"
vsphere_server = "${vsphere_url}"
ipam = "ipam.vmc.ci.openshift.org"
cluster_id = "${cluster_name}"
base_domain = "${base_domain}"
cluster_domain = "${cluster_domain}"
ssh_public_key_path = "${ssh_pub_key_path}"
compute_memory = "16384"
compute_num_cpus = "4"
vm_network = "${vsphere_portgroup}"
vm_dns_addresses = ["${dns_server}"]
bootstrap_ip_address = "${bootstrap_ip_address}"
lb_ip_address = "${lb_ip_address}"

compute_ip_addresses = ${compute_ip_addresses}
control_plane_ip_addresses = ${control_plane_ip_addresses}
EOF

echo "$(date -u --rfc-3339=seconds) - Create secrets.auto.tfvars..."
cat >"${SHARED_DIR}/secrets.auto.tfvars" <<-EOF
vsphere_password="${GOVC_PASSWORD}"
vsphere_user="${GOVC_USERNAME}"
ipam_token=""
EOF

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
  "${SHARED_DIR}/install-config.yaml"

echo "$(date +%s)" >"${SHARED_DIR}/TEST_TIME_INSTALL_START"

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

echo "$(date +%s)" >"${SHARED_DIR}/TEST_TIME_INSTALL_END"

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
