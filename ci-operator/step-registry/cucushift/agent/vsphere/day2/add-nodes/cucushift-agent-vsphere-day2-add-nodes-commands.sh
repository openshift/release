#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

[ -z "${ADDITIONAL_WORKERS_DAY2}" ] && {
  echo "\$ADDITIONAL_WORKERS_DAY2 is not filled. Failing."
  exit 1
}

export HOME=/tmp

SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json
if [[ "${CLUSTER_PROFILE_NAME:-}" == "vsphere-elastic" ]]; then
    SUBNETS_CONFIG="${SHARED_DIR}/subnets.json"
fi

declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

declare vsphere_datacenter
declare vsphere_datastore
declare dns_server

if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi

dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
gateway_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gatewayipv6' "${SUBNETS_CONFIG}")
cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].cidr' "${SUBNETS_CONFIG}")
cidr_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].CidrIPv6' "${SUBNETS_CONFIG}")

# select a hardware version for testing
hw_versions=(15 17 18 19)
hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % +hw_available_versions))
target_hw_version=${hw_versions[$selected_hw_version_index]}

echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >>"${SHARED_DIR}"/vsphere_context.sh

folder_name=$(<"${SHARED_DIR}"/cluster-name.txt)
total_workers="${ADDITIONAL_WORKERS_DAY2}"
declare -a mac_addresses=()

for ((i = 0; i < total_workers; i++)); do
  mac_addresses+=(00:50:56:ac:b8:1"$i")
  echo "${mac_addresses[$i]}"
done

declare -a hostnames=()
for ((i = 0; i < total_workers; i++)); do
  hostnames+=("${folder_name}-additional-worker-$i")
  echo "${hostnames[$i]}"
done

for ((i = 0; i < total_workers; i++)); do
  ipaddress=$(jq -r --argjson N $((i + 10)) --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
  ipv6_address=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].StartIPv6Address' "${SUBNETS_CONFIG}")
  ipv4_addresses+="${ipaddress},"
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
            - ip: "${ipv6_address%%::*}::"$((i + 12))
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
  if [[ ${IP_FAMILIES} == "IPv4" ]]; then
    ipv6=""
    route_ipv6=""
  fi
  if [[ ${IP_FAMILIES} == "IPv6" ]]; then
    ipv4=""
    route_ipv4=""
  fi
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
done >>"${SHARED_DIR}/nodes-config.yaml.patch"

nodes_config_patch="${SHARED_DIR}/nodes-config.yaml.patch"
#create agent node config file
cat >"${SHARED_DIR}/nodes-config.yaml" <<EOF
hosts: []
EOF

nodes_config="${SHARED_DIR}/nodes-config.yaml"
#Add hosts details to the nodes-config.yaml
yq-v4 --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
  "${nodes_config}" - <<<"$(cat "${nodes_config_patch}")"

echo "Creating agent node image..."
dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" "${SHARED_DIR}"/nodes-config.yaml

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

oc adm node-image create --dir="${dir}" --insecure=true

echo "node_${folder_name}.iso" >"${SHARED_DIR}"/node-iso.txt
node_iso=$(<"${SHARED_DIR}"/node-iso.txt)

echo "uploading ${node_iso} to iso-datastore.."

for ((i = 0; i < 3; i++)); do
  if govc datastore.upload -ds "${vsphere_datastore}" node.iso agent-installer-isos/"${node_iso}"; then
    echo "$(date -u --rfc-3339=seconds) - Agent node ISO has been uploaded successfully!!"
    status=0
    break
  else
    echo "$(date -u --rfc-3339=seconds) - Failed to upload agent node iso. Retrying..."
    status=1
    sleep 2
  fi
done
if [ "$status" -ne 0 ]; then
  echo "Agent node ISO upload failed after 3 attempts!!!"
  exit 1
fi

for ((i = 0; i < total_workers; i++)); do
  vm_name=${hostnames[$i]}
  echo "creating Vm $vm_name.."
  govc vm.create \
    -m=16384 \
    -g=coreos64Guest \
    -c=4 \
    -disk=120GB \
    -net="${vsphere_portgroup}" \
    -firmware=efi \
    -on=false \
    -version vmx-"${target_hw_version}" \
    -folder="/${vsphere_datacenter}/vm/${folder_name}" \
    -iso-datastore="${vsphere_datastore}" \
    -iso=agent-installer-isos/"${node_iso}" \
    "$vm_name"

  govc vm.change \
    -e="disk.EnableUUID=1" \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc vm.change \
    -nested-hv-enabled=true \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc device.boot \
    -secure \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc vm.network.change \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}" \
    -net "${vsphere_portgroup}" \
    -net.address "${mac_addresses[$i]}" ethernet-0

  govc vm.power \
    -on=true "/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"
done

# To check if there are pending CSRs
function wait_for_pending_csrs_and_approve() {
  for ((i = 0; i < 3; i++)); do
    pending_csrs=$(oc get csr | grep Pending | awk '{print $1}')
    if [ -n "$pending_csrs" ]; then
      for csr in $pending_csrs; do
        echo "Approving CSR: $csr"
        oc adm certificate approve "$csr"
      done
      echo "All pending CSRs approved."
      break
    fi
    echo "No pending CSRs found. Waiting..."
    sleep 30
  done
}

echo "Monitoring additional worker nodes IPs ${ipv4_addresses} to join the cluster"
sleep 60
oc adm node-image monitor --ip-addresses "${ipv4_addresses%,}" 2>&1 | tee output.txt &

for ((i = 0; i < 20; i++)); do
  if grep -q "Kubelet" output.txt; then
    # TODO: Handle CSR approvals based on pending CSRs that require DNS entries for nodes.
    wait_for_pending_csrs_and_approve
    sleep 20
    wait_for_pending_csrs_and_approve
    break
  fi
  sleep 30
done

# Add operators status checking until monitoring enhanced to do this
echo "Ensure that all the cluster operators remain stable and ready"
oc adm wait-for-stable-cluster --minimum-stable-period=3m --timeout=15m