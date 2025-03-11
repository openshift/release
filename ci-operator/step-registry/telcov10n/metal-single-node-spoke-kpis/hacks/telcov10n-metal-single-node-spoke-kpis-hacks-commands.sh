#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function load_env {

  #### Spoke cluster
  SPOKE_CLUSTER_NAME="spoke-${OCP_SPOKE_VERSION//./-}"
  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_CLUSTER_NIC_MAC="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/network_spoke_mac_address)"
  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_IPv4="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/network_spoke_ipv4_address)"
  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_IPv6="$(cat /var/run/telcov10n/helix72-telcoqe-eng-rdu2-dc-redhat-com/network_spoke_ipv6_address)"
}

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

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

  local cluster_base_domain
  cluster_base_domain="$(cat /var/run/telcov10n/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_domain_name)"
  set -x
  echo -n "${cluster_base_domain}" >| ${SHARED_DIR}/base_domain
  set +x
}

function update_spoke_cluster_name {

  echo "************ telcov10n update spoke cluster name ************"

  local spoke_cluster_name="spoke-${OCP_SPOKE_VERSION//./-}"
  set -x
  echo -n "${spoke_cluster_name}" >| ${SHARED_DIR}/spoke_cluster_name
  set +x
}

function update_dns_domains {

  local spoke_cluster_name="spoke-${OCP_SPOKE_VERSION//./-}"
  local cluster_base_domain
  cluster_base_domain="$(cat /var/run/telcov10n/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_domain_name)"
  local spoke_base_domain="${spoke_cluster_name}.${cluster_base_domain}"

  echo "************ telcov10n update DNS domains for the Spoke cluster '${spoke_cluster_name}' ************"

  echo
  echo -n "Using ${spoke_base_domain} domain name..."
  echo

  local network_spoke_mac_address="${BAREMETAL_SPOKE_CLUSTER_NIC_MAC}"
  local api_ipv4="${BAREMETAL_SPOKE_IPv4}"
  local api_ipv6="${BAREMETAL_SPOKE_IPv6}"
  local file_name="${network_spoke_mac_address//:/-}"
  local remote_path="/etc/NetworkManager/dnsmasq.d/88-sno-spoke-with-mac_${file_name}.conf"
  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
    "${remote_path}" "${network_spoke_mac_address}" "${spoke_base_domain}" "${api_ipv4:-}" "${api_ipv6:-}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

dn_conf="${1}"
mac="${2}"
spoke_domain="${3}"
ipv4="${4:-}"
ipv6="${5:-}"

set -x
  sudo cat <<EO-dns-file >| ${dn_conf}
#
# OCP SPOKE cluster API
#
EO-dns-file

if [[ -n ${ipv4} ]]; then
  sudo cat <<EO-dns-file >> ${dn_conf}
dhcp-host=${mac},${ipv4}
address=/api.${spoke_domain}/${ipv4}
address=/api-int.${spoke_domain}/${ipv4}
address=/.apps.${spoke_domain}/${ipv4}
EO-dns-file
fi

if [[ -n ${ipv6} ]]; then
  sudo cat <<EO-dns-file >> ${dn_conf}
# dhcp-host=id:00:03:00:01:${mac},[${ipv6}]
# address=/api.${spoke_domain}/${ipv6}
# address=/api-int.${spoke_domain}/${ipv6}
# address=/.apps.${spoke_domain}/${ipv6}
EO-dns-file
fi

sudo systemctl reload-or-restart NetworkManager
EOF

  set +x
  echo
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
  update_dns_domains
  # use_shared_ssh_keys_from_vault
}

function main {

  load_env

  setup_aux_host_ssh_access
  set_spoke_cluster_kubeconfig
  hack_spoke_deployment
}

main
