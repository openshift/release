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

declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup
declare dns_server
declare vsphere_url
source "${SHARED_DIR}/vsphere_context.sh"

openshift_install_path="/var/lib/openshift-install"

start_master_num=4
end_master_num=$((start_master_num + MASTER_REPLICAS - 1))

start_worker_num=$((end_master_num + 1))
end_worker_num=$((start_worker_num + WORKER_REPLICAS - 1))

master_ips=()
worker_ips=()

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${vsphere_portgroup}"))

  machine_cidr="192.168.${third_octet}.0/25"
  netmask="255.255.255.128"
  gateway="192.168.${third_octet}.1"
  bootstrap_ip_address="192.168.${third_octet}.3"
  lb_ip_address="192.168.${third_octet}.2"

  for num in $(seq "$start_master_num" "$end_master_num"); do
    master_ips+=("192.168.${third_octet}.$num")
  done

  if [ "${WORKER_REPLICAS}" -ne 0 ]; then
    for num in $(seq "$start_worker_num" "$end_worker_num"); do
      worker_ips+=("192.168.${third_octet}.$num")
    done
  fi
else
  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
  gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
  netmask=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].mask' "${SUBNETS_CONFIG}")

  lb_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[2]' "${SUBNETS_CONFIG}")
  bootstrap_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[3]' "${SUBNETS_CONFIG}")
  machine_cidr=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}")

  printf "***** DEBUG dns: %s lb: %s bootstrap: %s cidr: %s ******\n" "$dns_server" "$lb_ip_address" "$bootstrap_ip_address" "$machine_cidr"

  control_plane_idx=0
  control_plane_addrs=()
  control_plane_hostnames=()
  for n in $(seq "$start_master_num" "$end_master_num"); do
    control_plane_addrs+=("$(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
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
    compute_addrs+=("$(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
    compute_hostnames+=("compute-$((compute_idx++))")
  done

  printf "**** compute DEBUG %s ******\n" "${compute_addrs[@]}"

  printf -v compute_ip_addresses "\"%s\"," "${compute_addrs[@]}"
  compute_ip_addresses="[${compute_ip_addresses%,}]"

fi

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

printf "IBMCloud\ndatacenter-2" >"${SHARED_DIR}/ova-datacenters"
printf "mdcnc-ds-1\nmdcnc-ds-4" >"${SHARED_DIR}/ova-datastores"
printf "vcs-mdcnc-workload-1\nvcs-mdcnc-workload-4" >"${SHARED_DIR}/ova-clusters"

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

# select a hardware version for testing
hw_versions=(15 17 19)
hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % ${hw_available_versions}))
target_hw_version=${hw_versions[$selected_hw_version_index]}
echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"
vm_template=${vm_template}-hw${target_hw_version}

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >>${SHARED_DIR}/vsphere_context.sh
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

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
  DNS_RECORD='{
  "Action": "${ACTION}",
  "ResourceRecordSet": {
    "Name": "${CLUSTER_NAME}-${VM_NAME}.${CLUSTER_DOMAIN}.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [{"Value": "${IP_ADDRESS}"}]
    }
  }'

  for (( node=0; node < ${MASTER_REPLICAS}; node++)); do
    echo "Creating DNS entry for ${compute_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${control_plane_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${control_plane_ip_addresses[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done
  for (( node=0; node < ${WORKER_REPLICAS}; node++)); do
    echo "Creating DNS entry for ${compute_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${compute_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${compute_ip_addresses[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done

  echo "Creating json to create Node DNS records..."
  echo ${ROUTE53_CREATE_JSON} > "${SHARED_DIR}"/dns-nodes-create.json

  echo "Creating json file to delete Node DNS records..."
  echo ${ROUTE53_DELETE_JSON} > "${SHARED_DIR}"/dns-nodes-delete.json
fi

${platform_required} && cat >>"${install_config}" <<EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: ${MASTER_REPLICAS}
  platform:
    vsphere:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
compute:
- name: "worker"
  replicas: ${WORKER_REPLICAS}
  platform:
    vsphere:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
       - "us-west-1"
platform:
  vsphere:
    vCenter: "${vsphere_url}"
    username: "${GOVC_USERNAME}"
    password: ${GOVC_PASSWORD}
    network: ${vsphere_portgroup}
    datacenter: "IBMCloud"
    cluster: vcs-mdcnc-workload-1
    defaultDatastore: mdcnc-ds-shared
    folder: "/IBMCloud/vm/${cluster_name}"
    failureDomains:
    - name: us-east-1
      region: us-east
      zone: us-east-1a
      topology:
        computeCluster: /IBMCloud/host/vcs-mdcnc-workload-1
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-1
    - name: us-east-2
      region: us-east
      zone: us-east-2a
      topology:
        computeCluster: /IBMCloud/host/vcs-mdcnc-workload-2
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-2
    - name: us-east-3
      region: us-east
      zone: us-east-3a
      topology:
        computeCluster: /IBMCloud/host/vcs-mdcnc-workload-3
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-3
    - name: us-west-1
      region: us-west
      zone: us-west-1a
      topology:
        datacenter: datacenter-2
        computeCluster: /datacenter-2/host/vcs-mdcnc-workload-4
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-4
        folder: "/datacenter-2/vm/${cluster_name}"

networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

#set machine cidr if proxy is enabled
if grep 'httpProxy' "${install_config}"; then
  cat >>"${install_config}" <<EOF
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF
fi

echo "$(date -u --rfc-3339=seconds) - ***** DEBUG ***** DNS: ${dns_server}"

echo "$(date -u --rfc-3339=seconds) - Create terraform.tfvars ..."
cat >"${SHARED_DIR}/terraform.tfvars" <<-EOF
machine_cidr = "${machine_cidr}"
vm_template = "${vm_template}"
vsphere_server = "${vsphere_url}"
ipam = "ipam.vmc.ci.openshift.org"
cluster_id = "${cluster_name}"
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
control_plane_count = ${MASTER_REPLICAS}
compute_count = ${WORKER_REPLICAS}
failure_domains = [
    {
        datacenter = "IBMCloud"
        cluster = "vcs-mdcnc-workload-1"
        datastore = "mdcnc-ds-1"
        network = "${vsphere_portgroup}"
        distributed_virtual_switch_uuid = "50 05 37 56 0d b0 eb 3a-e4 4c 68 33 1b 64 9e a2"
    },
    {
        datacenter = "IBMCloud"
        cluster = "vcs-mdcnc-workload-2"
        datastore = "mdcnc-ds-2"
        network = "${vsphere_portgroup}"
        distributed_virtual_switch_uuid = "50 05 37 56 0d b0 eb 3a-e4 4c 68 33 1b 64 9e a2"
    },
    {
        datacenter = "IBMCloud"
        cluster = "vcs-mdcnc-workload-3"
        datastore = "mdcnc-ds-3"
        network = "${vsphere_portgroup}"
        distributed_virtual_switch_uuid = "50 05 37 56 0d b0 eb 3a-e4 4c 68 33 1b 64 9e a2"
    },
    {
        datacenter = "datacenter-2"
        cluster = "vcs-mdcnc-workload-4"
        datastore = "mdcnc-ds-4"
        network = "${vsphere_portgroup}"
        distributed_virtual_switch_uuid = "50 05 92 5b 73 ea fd cb-1c 02 ad e4 df fd fb 8c"
    }
]
"@
EOF

echo "$(date -u --rfc-3339=seconds) - Create variables.ps1 ..."
cat >"${SHARED_DIR}/variables.ps1" <<-EOF
\$clustername = "${cluster_name}"
\$basedomain = "${base_domain}"
\$clusterdomain = "${cluster_domain}"
\$sshkeypath = "${ssh_pub_key_path}"

\$machine_cidr = "${machine_cidr}"

\$vm_template = "${vm_template}"
\$vcenter = "${vsphere_url}"
\$vcentercredpath = "secrets/vcenter-creds.xml"

\$ipam = "ipam.vmc.ci.openshift.org"

\$dns = "${dns_server}"
\$gateway = "${gateway}"
\$netmask ="${netmask}"

\$bootstrap_ip_address = "${bootstrap_ip_address}"
\$lb_ip_address = "${lb_ip_address}"

\$control_plane_memory = 16384
\$control_plane_num_cpus = 4
\$control_plane_count = ${MASTER_REPLICAS}
\$control_plane_ip_addresses = $(echo ${control_plane_ip_addresses} | tr -d [])
\$control_plane_hostnames = $(printf "\"%s\"," "${control_plane_hostnames[@]}" | sed 's/,$//')

\$compute_memory = 16384
\$compute_num_cpus = 4
\$compute_count = ${WORKER_REPLICAS}
\$compute_ip_addresses = $(echo ${compute_ip_addresses} | tr -d [])
\$compute_hostnames = $(printf "\"%s\"," "${compute_hostnames[@]}" | sed 's/,$//')

\$failure_domains = @"
[
    {
        "datacenter": "IBMCloud",
        "cluster": "vcs-mdcnc-workload-1",
        "datastore": "mdcnc-ds-1",
        "network": "${vsphere_portgroup}"
    },
    {
        "datacenter": "IBMCloud",
        "cluster": "vcs-mdcnc-workload-2",
        "datastore": "mdcnc-ds-2",
        "network": "${vsphere_portgroup}"
    },
    {
        "datacenter": "IBMCloud",
        "cluster": "vcs-mdcnc-workload-3",
        "datastore": "mdcnc-ds-3",
        "network": "${vsphere_portgroup}"
    },
    {
        "datacenter": "datacenter-2",
        "cluster": "vcs-mdcnc-workload-4",
        "datastore": "mdcnc-ds-4",
        "network": "${vsphere_portgroup}"
    }
]
"@
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
