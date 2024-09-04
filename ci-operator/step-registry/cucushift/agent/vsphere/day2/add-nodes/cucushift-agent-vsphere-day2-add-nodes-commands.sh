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

source "${SHARED_DIR}/vsphere_context.sh"
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

declare target_hw_version
declare vsphere_portgroup
declare vsphere_datacenter
declare vsphere_datastore
declare dns_server

source "${SHARED_DIR}/network-config.txt"
declare dns_server
declare gateway
declare gateway_ipv6
declare cidr
declare cidr_ipv6

folder_name=$(<"${SHARED_DIR}"/cluster-name.txt)
declare -a additional_worker_ipv4Addresses
mapfile -t additional_worker_ipv4Addresses <"${SHARED_DIR}"/additional_worker_ipv4Addresses.txt

declare -a additional_worker_ipv6Addresses
mapfile -t additional_worker_ipv6Addresses <"${SHARED_DIR}"/additional_worker_ipv6Addresses.txt

declare -a additional_worker_hostnames
mapfile -t additional_worker_hostnames <"${SHARED_DIR}"/additional_worker_hostnames.txt

declare -a mac_addresses=()

for ((i = 0; i < ${#additional_worker_hostnames[@]}; i++)); do
  mac_addresses+=(00:50:56:ac:b8:1"$i")
  echo "${mac_addresses[$i]}"
done

for ((i = 0; i < ${#additional_worker_hostnames[@]}; i++)); do
  # storing ipv4_addresses for monitoring
  ipv4_addresses+="${additional_worker_ipv4Addresses[$i]},"
  ipv4="
        ipv4:
          enabled: true
          address:
            - ip: ${additional_worker_ipv4Addresses[$i]}
              prefix-length: ${cidr}
          dhcp: false"
  ipv6="
        ipv6:
          enabled: true
          address:
            - ip: ${additional_worker_ipv6Addresses[$i]}
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
  echo " - hostname: ${additional_worker_hostnames[$i]}
   role: $(echo "${additional_worker_hostnames[$i]}" | rev | cut -d'-' -f2 | rev | cut -f1)
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

for ((i = 0; i < ${#additional_worker_hostnames[@]}; i++)); do
  vm_name=${additional_worker_hostnames[$i]}
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

echo "Monitoring additional worker nodes IPs ${ipv4_addresses} to join the cluster"
sleep 60
# shellcheck disable=SC2001
oc adm node-image monitor --ip-addresses "${ipv4_addresses%,}" 2>&1 | \
tee output.txt | while IFS= read -r line; do
  if [[ "$line" = *"kube-apiserver-client-kubelet"* ]]; then
    node_ip=$(echo "$line" | sed 's/^.*Node \(.*\): CSR.*$/\1/')
    csr=$(echo "$line" | sed 's/^.*CSR \([^ ]*\).*$/\1/')
    echo "Approving CSR $csr for node $node_ip"
    oc adm certificate approve "$csr"
  fi
  if [[ "$line" = *"kubelet-serving"* ]]; then
    node_ip=$(echo "$line" | sed 's/^.*Node \(.*\): CSR.*$/\1/')
    csr=$(echo "$line" | sed 's/^.*CSR \([^ ]*\).*$/\1/')
    echo "Approving CSR $csr for node $node_ip"
    oc adm certificate approve "$csr"
  fi
done
EXIT_STATUS="${PIPESTATUS[0]}"
echo "Exiting with status $EXIT_STATUS"
exit "$EXIT_STATUS"
