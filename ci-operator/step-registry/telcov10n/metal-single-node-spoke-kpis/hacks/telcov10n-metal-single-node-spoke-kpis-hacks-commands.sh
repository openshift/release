#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  if [ -f "${SHARED_DIR}/spoke_cluster_name" ]; then
    SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke_cluster_name)"
  else
    SPOKE_CLUSTER_NAME=${NAMESPACE}
  fi
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
}

function update_host_and_master_yaml_files {

  echo "************ telcov10n update host and master Yaml files ************"

  # ${SHARED_DIR}/hosts.yaml file expected values to be available:
  server_hostname="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/name)"
  redfish_scheme="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/redfish_scheme)"
  bmc_address="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/bmc_address)"
  redfish_base_uri="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/redfish_base_uri)"
  mac="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/network_spoke_mac_address)"
  root_device="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/root_device)"
  root_dev_hctl="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/root_dev_hctl)"
  baremetal_iface="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/baremetal_iface)"
  ipi_disabled_ifaces="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/ipi_disabled_ifaces)"

  bmc_user="$(cat /var/run/telcov10n/ansible-group-all/bmc_user)"
  bmc_pass="$(cat /var/run/telcov10n/ansible-group-all/bmc_password)"

  cat <<EOF >| ${SHARED_DIR}/hosts.yaml
- mac: ${mac}
  ip: ${ip:="no-needed-value"}
  ipv6: ${ipv6:="no-needed-value"}
  root_device: ${root_device}
  root_dev_hctl: ${root_dev_hctl}
  ipi_disabled_ifaces: "${ipi_disabled_ifaces}"
  baremetal_iface: ${baremetal_iface}
  bmc_address: ${bmc_address}
  bmc_user: ${bmc_user}
  bmc_pass: ${bmc_pass}
  redfish_base_uri: ${redfish_base_uri}
  redfish_scheme: ${redfish_scheme}
  name: ${server_hostname}
EOF

  cat <<EOF >| ${SHARED_DIR}/master.yaml
- bmc_user: ${bmc_user}
  bmc_pass: ${bmc_pass}
EOF

}

function update_base_domain {

  echo "************ telcov10n update base domain ************"

  cluster_base_domain="$(cat /var/run/telcov10n/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_domain_name)"
  set -x
  echo -n "${cluster_base_domain}" >| ${SHARED_DIR}/base_domain
  set +x
}

function update_spoke_cluster_name {

  echo "************ telcov10n update spoke cluster name ************"

  spoke_cluster_name="spoke-${OCP_SPOKE_VERSION//./-}"
  set -x
  echo -n "${spoke_cluster_name}" >| ${SHARED_DIR}/spoke_cluster_name
  set +x
}

function use_shared_ssh_keys_from_vault {

  echo "************ telcov10n use shared ssh keys from vault ************"

  gitea_project="${GITEA_NAMESPACE}"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${gitea_project}
  ssh_pub_key_file="${ssh_pri_key_file}.pub"

  #### SSH Private key
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key > ${ssh_pri_key_file}
  chmod 0600 ${ssh_pri_key_file}

  #### SSH Public key
  cat /var/run/telcov10n/ansible-group-all/ssh_public_key >| ${ssh_pub_key_file}
  chmod 0644 ${ssh_pub_key_file}

  ls -lhtr ${ssh_pri_key_file}*
}

function hack_spoke_deployment {

  echo "************ telcov10n hack spoke deployment values ************"

  update_host_and_master_yaml_files
  update_spoke_cluster_name
  update_base_domain
  # use_shared_ssh_keys_from_vault
}

function main {
  set_spoke_cluster_kubeconfig
  hack_spoke_deployment
}

main
