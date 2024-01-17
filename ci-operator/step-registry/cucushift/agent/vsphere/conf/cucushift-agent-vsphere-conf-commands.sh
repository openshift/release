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

[ -z "${WORKERS}" ] && {
  echo "\$WORKERS is not filled. Failing."
  exit 1
}
[ -z "${MASTERS}" ] && {
  echo "\$MASTERS is not filled. Failing."
  exit 1
}

export HOME=/tmp
SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json

declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"
source "${SHARED_DIR}/govc.sh"

declare vsphere_url
declare GOVC_USERNAME
declare GOVC_PASSWORD
declare vsphere_datacenter
declare vsphere_datastore
declare dns_server
declare vsphere_cluster

machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)
if [[ ${vsphere_portgroup} == *"segment"* ]]; then
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${vsphere_portgroup}"))
  gateway="192.168.${third_octet}.1"
  rendezvous_ip_address="192.168.${third_octet}.4"
else
  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
  gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
  gateway_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gatewayipv6' "${SUBNETS_CONFIG}")
  cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].cidr' "${SUBNETS_CONFIG}")
  cidr_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].CidrIPv6' "${SUBNETS_CONFIG}")
  machine_cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}")
  # ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway
  rendezvous_ip_address=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[4]' "${SUBNETS_CONFIG}")

fi

echo "${rendezvous_ip_address}" >"${SHARED_DIR}"/node-zero-ip.txt

pull_secret_path=${CLUSTER_PROFILE_DIR}/pull-secret
build02_secrets="/var/run/vault/secrets/.dockerconfigjson"
extract_build02_auth=$(jq -c '.auths."registry.apps.build02.vmc.ci.openshift.org"' ${build02_secrets})
final_pull_secret=$(jq -c --argjson auth "$extract_build02_auth" '.auths["registry.apps.build02.vmc.ci.openshift.org"] += $auth' "${pull_secret_path}")

echo "${final_pull_secret}" >>"${SHARED_DIR}"/pull-secrets
echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create base-domain.txt
echo "vmc-ci.devcluster.openshift.com" >"${SHARED_DIR}"/base-domain.txt
base_domain=$(<"${SHARED_DIR}"/base-domain.txt)

pull_secret=$(<"${SHARED_DIR}/pull-secrets")

# Create cluster-name.txt
echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/cluster-name.txt
cluster_name=$(<"${SHARED_DIR}"/cluster-name.txt)

# Add build02 secrets if the mirror registry secrets are not available.
if [ ! -f "${SHARED_DIR}/pull_secret_ca.yaml.patch" ]; then
  yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
pullSecret: >
  ${pull_secret}
EOF
fi

yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "${SHARED_DIR}/install-config.yaml" - <<<"
platform:
  vsphere:
    failureDomains:
    - name: test-failure-baseDomain
      region: changeme-region
      server: ${vsphere_url}
      topology:
        computeCluster: /${vsphere_datacenter}/host/${vsphere_cluster}
        datacenter: ${vsphere_datacenter}
        datastore: /${vsphere_datacenter}/datastore/${vsphere_datastore}
        networks:
        - ${vsphere_portgroup}
        resourcePool: /${vsphere_datacenter}/host/${vsphere_cluster}/Resources
        folder: /${vsphere_datacenter}/vm/${cluster_name}
      zone: changeme-zone
    vcenters:
    - datacenters:
      - ${vsphere_datacenter}
      server: ${vsphere_url}
      password: ${GOVC_PASSWORD}
      user: ${GOVC_USERNAME}
"

if [ "${MASTERS}" -eq 1 ]; then
  yq --inplace 'del(.platform)' "${SHARED_DIR}"/install-config.yaml
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<<"
platform:
  none: {}
"
fi

if [[ ${IP_FAMILIES} == "IPv4" ]]; then
  yq e --inplace 'del(.networking)' "${SHARED_DIR}"/install-config.yaml
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
networking:
  machineNetwork:
  - cidr: ${machine_cidr}
EOF
fi

cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
baseDomain: ${base_domain}
controlPlane:
  name: master
  replicas: ${MASTERS}
compute:
- name: worker
  replicas: ${WORKERS}
EOF

# Create cluster-domain.txt
echo "${cluster_name}.${base_domain}" >"${SHARED_DIR}"/cluster-domain.txt

# select a hardware version for testing
hw_versions=(15 17 18 19)
hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % +hw_available_versions))
target_hw_version=${hw_versions[$selected_hw_version_index]}

echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >>"${SHARED_DIR}"/vsphere_context.sh

total_host="$((MASTERS + WORKERS))"
declare -a mac_addresses=()

for ((i = 0; i < total_host; i++)); do
  mac_addresses+=(00:50:56:ac:b8:0"$i")
  echo "${mac_addresses[$i]}"
done >"${SHARED_DIR}"/mac-addresses.txt

declare -a hostnames=()
for ((i = 0; i < total_host; i++)); do
  if [ "${WORKERS}" -gt 0 ]; then
    hostnames+=("${cluster_name}-master-$i")
    hostnames+=("${cluster_name}-worker-$i")
    echo "${hostnames[$i]}"
  else
    hostnames+=("${cluster_name}-master-$i")
    echo "${hostnames[$i]}"
  fi
done >"${SHARED_DIR}"/hostnames.txt

for ((i = 0; i < total_host; i++)); do
  ipaddress=""
  if [[ ${vsphere_portgroup} == *"segment"* ]]; then
    ipaddress=192.168.${third_octet}.$((i + 4))
    cidr=25
  else
    ipaddress=$(jq -r --argjson N $((i + 4)) --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
    ipv6_address=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].StartIPv6Address' "${SUBNETS_CONFIG}")
  fi
  ipv4="
        ipv4:
          enabled: true
          address:
            - ip: ${ipaddress}
              prefix-length: ${cidr}
          dhcp: false"
  ipv6="
        ipv6:
          enabled: true
          address:
            - ip: "${ipv6_address%%::*}::"$((i + 6))
              prefix-length: ${cidr_ipv6}
          dhcp: false"
  route_ipv4="
          - destination: 0.0.0.0/0
            next-hop-address: ${gateway}
            next-hop-interface: ens32
            table-id: 254"
  route_ipv6="
          - destination: ::/0
            next-hop-address: ${gateway_ipv6}
            next-hop-interface: ens32
            table-id: 254"
  # Single-stack override conditions
  if [[ ${IP_FAMILIES} == "IPv4" ]]; then ipv6=""; route_ipv6=""; fi
  if [[ ${IP_FAMILIES} == "IPv6" ]]; then ipv4=""; route_ipv4=""; fi
  echo " - hostname: ${hostnames[$i]}
   role: $(echo "${hostnames[$i]}" | rev | cut -d'-' -f2 | rev | cut -f1)
   interfaces:
    - name: ens32
      macAddress: ${mac_addresses[$i]}
   networkConfig:
    interfaces:
      - name: ens32
        type: ethernet
        state: up
        mac-address: ${mac_addresses[$i]}${ipv4}${ipv6}
    dns-resolver:
     config:
      server:
       - ${dns_server}
    routes:
     config:${route_ipv4}${route_ipv6}"
done >>"${SHARED_DIR}/agent-config.yaml.patch"

agent_config_patch="${SHARED_DIR}/agent-config.yaml.patch"
#create agent config file
cat >"${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1alpha1
kind: AgentConfig
rendezvousIP: ${rendezvous_ip_address}
hosts: []
EOF

agent_config="${SHARED_DIR}/agent-config.yaml"
#Add hosts details to the agent-config.yaml
yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
  "${agent_config}" - <<<"$(cat "${agent_config_patch}")"

echo "Installing from initial release $RELEASE_IMAGE_LATEST"
oc adm release extract -a "$pull_secret_path" "$RELEASE_IMAGE_LATEST" \
  --command=openshift-install --to=/tmp

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
  "${SHARED_DIR}"/{install-config.yaml,agent-config.yaml}

echo "Creating agent image..."
/tmp/openshift-install agent create image --dir="${dir}" --log-level debug &

if ! wait $!; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit 1
fi

curl -s -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o ${HOME}/glx.tar.gz && tar -C ${HOME} -xvf ${HOME}/glx.tar.gz govc && rm -f ${HOME}/glx.tar.gz

echo "agent.x86_64_${cluster_name}.iso" >"${SHARED_DIR}"/agent-iso.txt
agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)
echo "uploading ${agent_iso} to iso-datastore.."

for ((i = 0; i < 3; i++)); do
  if /tmp/govc datastore.upload -ds "${vsphere_datastore}" agent.x86_64.iso agent-installer-isos/"${agent_iso}"; then
    echo "$(date -u --rfc-3339=seconds) - Agent ISO has been uploaded successfully!!"
    status=0
    break
  else
    echo "$(date -u --rfc-3339=seconds) - Failed to upload agent iso. Retrying..."
    status=1
    sleep 2
  fi
done
if [ $status -ne 0 ]; then
  echo "Agent ISO upload failed after 3 attempts!!!"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Creating platform-conf.sh file for post installation..."
cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export VSPHERE_USERNAME="${GOVC_USERNAME}"
export VSPHERE_VCENTER="${vsphere_url}"
export VSPHERE_DATACENTER="${vsphere_datacenter}"
export VSPHERE_CLUSTER="${vsphere_cluster}"
export VSPHERE_DATASTORE="${vsphere_datastore}"
export VSPHERE_PASSWORD='${GOVC_PASSWORD}'
export VSPHERE_NETWORK='${vsphere_portgroup}'
export VSPHERE_FOLDER="${cluster_name}"
EOF

echo "Copying kubeconfig to the shared directory..."
cp -t "${SHARED_DIR}" \
  "${dir}/auth/kubeadmin-password" \
  "${dir}/auth/kubeconfig" \
  "${dir}/.openshift_install_state.json"
popd
