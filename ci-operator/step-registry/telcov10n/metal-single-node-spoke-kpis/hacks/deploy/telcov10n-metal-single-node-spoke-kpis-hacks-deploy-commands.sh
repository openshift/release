#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function define_spoke_cluster_name {

  #### Spoke cluster
  SPOKE_CLUSTER_NAME=${NAMESPACE}
}

function load_env {

  baremetal_host_path="${1}"

  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_CLUSTER_NIC_MAC="$(cat ${baremetal_host_path}/network_spoke_mac_address)"
  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_IPv4="$(cat ${baremetal_host_path}/network_spoke_ipv4_address)"
  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_IPv6="$(cat ${baremetal_host_path}/network_spoke_ipv6_address)"
}

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
}

function select_baremetal_host_from_pool {

  echo "************ telcov10n select a baremetal host from the pool ************"

  local host_lock_timestamp
  host_lock_timestamp=$(date -u +%s%N)
  # shellcheck disable=SC2044
  for host in $( \
    find /var/run/telcov10n/ \
      -maxdepth 1 \
      -type d \
      -exec bash -c 'f="$1" ; test -f "${f}"/pool_name && echo "${f}"/pool_name' shell {} \;); do
    baremetal_host_path="$(dirname ${host})"

    load_env "${baremetal_host_path}"

    echo
    echo "Selecting '${baremetal_host_path}/name)' host..."
    echo

    if [[ "$(cat ${host})" == "baremetal-spokes-kpis" ]];then
      local network_spoke_mac_address
      network_spoke_mac_address="$(cat ${baremetal_host_path}/network_spoke_mac_address)"
      local spoke_lock_filename="/var/run/lock/ztp-baremetal-pool/spoke-baremetal-${network_spoke_mac_address//:/-}.lock"
      try_to_lock_host "${AUX_HOST}" "${spoke_lock_filename}" "${host_lock_timestamp}" "${LOCK_TIMEOUT}"
      [[ "$(check_the_host_was_locked "${AUX_HOST}" "${spoke_lock_filename}" "${host_lock_timestamp}")" == "locked" ]] &&
      {
        update_host_and_master_yaml_files "$(dirname ${host})" ;
        return 0 ;
      }
    fi
  done

  echo
  echo "[FATAL] There is not available baremetal host where deploy the current Spoke cluster!!!"
  echo "For manual clean up, check out /var/run/lock/ztp-baremetal-pool/*.lock folder in your bastion host"
  echo "and remove the lock files that release those baremental host you consider is saved to unlock."
  echo
  exit 1
}

function update_host_and_master_yaml_files {

  echo "************ telcov10n update host and master Yaml files ************"

  baremetal_host_path="${1}"

  # ${SHARED_DIR}/hosts.yaml file expected values to be available:
  server_hostname="$(cat ${baremetal_host_path}/name)"
  redfish_scheme="$(cat ${baremetal_host_path}/redfish_scheme)"
  bmc_address="$(cat ${baremetal_host_path}/bmc_address)"
  redfish_base_uri="$(cat ${baremetal_host_path}/redfish_base_uri)"
  mac="$(cat ${baremetal_host_path}/network_spoke_mac_address)"
  root_device="$(cat ${baremetal_host_path}/root_device)"
  root_dev_hctl="$(cat ${baremetal_host_path}/root_dev_hctl)"
  baremetal_iface="$(cat ${baremetal_host_path}/baremetal_iface)"
  ipi_disabled_ifaces="$(cat ${baremetal_host_path}/ipi_disabled_ifaces)"

  bmc_user="$(cat /var/run/telcov10n/ansible-group-all/bmc_user)"
  bmc_pass="$(cat /var/run/telcov10n/ansible-group-all/bmc_password)"

  curl_="curl -sLk \
      $([ -n "${SOCKS5_PROXY}" ] && echo "-x ${SOCKS5_PROXY}") \
      -H 'OData-Version: 4.0' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -u ${bmc_user}:${bmc_pass} \
      https://${bmc_address}${redfish_base_uri}"
  echo -n "$curl_" >| ${SHARED_DIR}/curl_redfish_base_uri

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

function update_dns_domains {

  local cluster_base_domain
  cluster_base_domain="$(cat /var/run/telcov10n/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_domain_name)"
  local spoke_base_domain="${SPOKE_CLUSTER_NAME}.${cluster_base_domain}"

  echo "************ telcov10n update DNS domains for the Spoke cluster '${SPOKE_CLUSTER_NAME}' ************"

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

function hack_spoke_deployment {

  echo "************ telcov10n hack spoke deployment values ************"

  select_baremetal_host_from_pool
  update_base_domain
  update_dns_domains
}

function main {

  setup_aux_host_ssh_access
  define_spoke_cluster_name
  set_spoke_cluster_kubeconfig
  hack_spoke_deployment
}

main
