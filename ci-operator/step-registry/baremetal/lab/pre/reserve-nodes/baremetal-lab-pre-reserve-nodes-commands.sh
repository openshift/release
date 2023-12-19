#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

[ -z "${AUX_HOST}" ] && {  echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && {  echo "\$masters is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && {  echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && {  echo "\$architecture is not filled. Failing."; exit 1; }
[ "${ADDITIONAL_WORKERS}" -gt 0 ] && [ -z "${ADDITIONAL_WORKER_ARCHITECTURE}" ] && { echo "\$ADDITIONAL_WORKER_ARCHITECTURE is not filled. Failing."; exit 1; }

gnu_arch=$(echo "${architecture}" | sed 's/arm64/aarch64/;s/amd64/x86_64/')

# The hostname of nodes and the cluster names have limited length for BM.
# Other profiles add to the cluster_name the suffix "-${UNIQUE_HASH}".
echo "${NAMESPACE}" > "${SHARED_DIR}/cluster_name"
CLUSTER_NAME="${NAMESPACE}"

echo "Reserving nodes for baremetal installation (${masters} masters, ${workers} workers) $([ "$RESERVE_BOOTSTRAP" == true ] && echo "+ 1 bootstrap physical node")..."
timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" "${masters}" "${workers}" "${RESERVE_BOOTSTRAP}" "${gnu_arch}" \
  "${ADDITIONAL_WORKERS}" "${ADDITIONAL_WORKER_ARCHITECTURE}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

export BUILD_USER=ci-op BUILD_ID="${1}"

N_MASTERS="${2}"
N_WORKERS="${3}"
REQUEST_BOOTSTRAP_HOST="${4}"
ARCH="${5}"
ADDITIONAL_WORKERS="${6:-}"
ADDITIONAL_WORKER_ARCHITECTURE="${7:-}"

# shellcheck disable=SC2174
mkdir -m 755 -p {/var/builds,/opt/dnsmasq/tftpboot,/opt/html}/${BUILD_ID}
mkdir -m 777 -p /opt/nfs/${BUILD_ID}
touch /etc/hosts_pool_reserved

# The current implementation of the following scripts is different based on the auxiliary host. Keeping the script in
# the remote aux servers temporarily.
N_MASTERS=${N_MASTERS} N_WORKERS=${N_WORKERS} \
  REQUEST_BOOTSTRAP_HOST=${REQUEST_BOOTSTRAP_HOST} REQUEST_VIPS=true APPEND="false" ARCH="${ARCH}" /usr/bin/reserve-hosts.sh
# If the number of requested ADDITIONAL_WORKERS is greater than 0, we need to reserve the additional workers
if [ "${ADDITIONAL_WORKERS}" -gt 0 ]; then
  N_WORKERS="${ADDITIONAL_WORKERS}" N_MASTERS=0 RESERVE_BOOTSTRAP_HOST=false \
   ARCH="${ADDITIONAL_WORKER_ARCHITECTURE}" APPEND="true" REQUEST_VIPS=false reserve-hosts.sh
fi
EOF

echo "Node reservation concluded successfully."
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/*.yaml" "${SHARED_DIR}/"
more "${SHARED_DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'

echo "${AUX_HOST}" >> "${SHARED_DIR}/bastion_public_address"
echo "root" > "${SHARED_DIR}/bastion_ssh_user"


# Example host element from the list in the hosts.yaml file:
# - mac: 34:73:5a:9d:eb:e1 # The mac address of the interface connected to the baremetal network
#  vendor: dell
#  ip: *****
#  host: openshift-qe-054
#  arch: x86_64
#  root_device: /dev/sdb
#  root_dev_hctl: ""
#  provisioning_mac: 34:73:5a:9d:eb:e2 # The mac address of the interface connected to the provisioning network (based on dynamic native-vlan)
#  switch_port: ""
#  switch_port_v2: ge-1/0/23@10.1.233.31:22 # Port in the managed switch (JunOS)
#  ipi_disabled_ifaces: eno1 # Interfaces to disable in the hosts
#  baremetal_iface: eno2 # The interface connected to the baremetal network
#  bmc_address: openshift-qe-054-drac.mgmt..... # The address of the BMC
#  bmc_scheme: ipmi
#  bmc_base_uri: /
#  bmc_user: ... # these are the ipmi credentials
#  bmc_pass: ...
#  bmc_forwarded_port: ... # this is the port forwarded from the aux host to the bmc's ipmi port
#  console_kargs: tty1;ttyS0,115200n8 # The serial console kargs needed at boot time for allowing remote viewing of the console
#  transfer_protocol_type: http # VirtualMedia Transfer Protocol Type
#  redfish_user: ... # redfish credentials, ipmi and redfish credentials differ in some cases
#  redfish_password: ...
#  build_id: ci-op-testaget # not usually needed as it is the same as CLUSTER_NAME
#  build_user: ci-op
#  name: master-02 # This name must be either master or worker or bootstrap in order for the steps to set the role correctly
#  ipxe_via_vmedia: true # Whether to use ipxe via virtual media or not (some UEFI has no drivers for the network card being used)