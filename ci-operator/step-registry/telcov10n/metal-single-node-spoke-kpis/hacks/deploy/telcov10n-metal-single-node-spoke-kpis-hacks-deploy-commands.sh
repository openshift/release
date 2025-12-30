#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function extract_and_set_ocp_version {

  echo "************ telcov10n Extracting OCP version from JOB_NAME ************"

  echo "[INFO] JOB_NAME: ${JOB_NAME:-not set}"

  OCP_VERSION=$(extract_ocp_version)

  if [ -z "${OCP_VERSION}" ]; then
    echo "[ERROR] Could not extract OCP version from JOB_NAME"
    exit 1
  fi

  echo "[INFO] OCP Version: ${OCP_VERSION}"

  # Store OCP version for other steps
  echo -n "${OCP_VERSION}" >| ${SHARED_DIR}/ocp_version.txt

  export OCP_VERSION
}

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

# Track if we've already created the waiting request file (stored path for cleanup)
WAITING_FILE_PATH=""

function create_waiting_request_on_bastion {

  local spoke_lock_filename="${1}"

  # Only create the waiting file once per session
  # Each job gets a unique file (with timestamp) that only it will delete
  if [ -n "${WAITING_FILE_PATH}" ]; then
    return 0
  fi

  echo
  echo "************ telcov10n Registering wait request before lock attempt ************"
  echo

  local waiting_file
  waiting_file=$(create_waiting_request_file "${AUX_HOST}" "${spoke_lock_filename}" "${OCP_VERSION}")

  if [ -n "${waiting_file}" ]; then
    echo "[INFO] Created waiting request file: ${waiting_file}"
    echo "       This signals that a job with OCP version ${OCP_VERSION} is waiting."
    WAITING_FILE_PATH="${waiting_file}"
    # Store the path in SHARED_DIR for cleanup step
    echo -n "${waiting_file}" >| ${SHARED_DIR}/own_waiting_file.txt
  else
    echo "[WARNING] Failed to create waiting request file."
  fi

  echo
}

function validate_lock_for_higher_priority {

  local spoke_lock_filename="${1}"

  echo
  echo "************ telcov10n Validating lock acquisition for priority ************"
  echo

  # Check if there's a higher priority job waiting BEFORE removing our waiting file
  # This way, if we need to release the lock, our waiting file stays intact
  local check_result
  check_result=$(check_for_higher_priority_waiter "${AUX_HOST}" "${spoke_lock_filename}" "${OCP_VERSION}")

  if [[ "${check_result}" == quit:* ]]; then
    local higher_version=${check_result#quit:}
    echo
    echo "[WARNING] Lock acquired but a higher priority job is waiting!"
    echo "          Current job version: ${OCP_VERSION}"
    echo "          Higher version waiting: ${higher_version}"
    echo "          Releasing lock to allow higher priority job to proceed..."
    echo "          (Keeping own waiting file for next attempt)"
    echo
    # Release the lock to let the higher priority job acquire it
    # Keep our waiting file - we're still waiting!
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "rm -fv ${spoke_lock_filename}"
    return 1
  fi

  echo "[INFO] No higher priority jobs waiting. Proceeding with lock."

  # NOW remove our waiting file since we're proceeding
  if [ -n "${WAITING_FILE_PATH}" ]; then
    echo "[INFO] Removing own waiting file: ${WAITING_FILE_PATH}"
    remove_own_waiting_file "${AUX_HOST}" "${WAITING_FILE_PATH}"
    WAITING_FILE_PATH=""
    rm -f ${SHARED_DIR}/own_waiting_file.txt 2>/dev/null || true
  fi

  # Store lock filename for later use by other steps
  echo -n "${spoke_lock_filename}" >| ${SHARED_DIR}/spoke_lock_filename.txt

  return 0
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

      # Create waiting request file BEFORE trying to acquire lock (only once)
      # This ensures our presence is visible even if we immediately get the lock
      create_waiting_request_on_bastion "${spoke_lock_filename}"

      try_to_lock_host "${AUX_HOST}" "${spoke_lock_filename}" "${host_lock_timestamp}" "${LOCK_TIMEOUT}"
      if [[ "$(check_the_host_was_locked "${AUX_HOST}" "${spoke_lock_filename}" "${host_lock_timestamp}")" == "locked" ]]; then
        # Validate that no higher priority job is waiting
        if validate_lock_for_higher_priority "${spoke_lock_filename}"; then
          update_host_and_master_yaml_files "$(dirname ${host})"
          echo -n "yes" >| ${SHARED_DIR}/do_you_hold_the_lock_for_the_sno_spoke_cluster_server.txt
          return 0
        else
          # Higher priority job is waiting, lock was released
          # Our waiting file is still intact (not removed until validation passes)
          echo "[INFO] Will retry acquiring lock..."
        fi
      fi
    fi
  done

  return 1
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

  wait_until_command_is_ok "select_baremetal_host_from_pool" 1m "${LOCK_ACQUIRE_ATTEMPTS}" || ( \
    echo
    echo "[FATAL] There is not available baremetal host where deploy the current Spoke cluster!!!"
    echo "For manual clean up, check out /var/run/lock/ztp-baremetal-pool/*.lock folder in your bastion host"
    echo "and remove the lock files that release those baremental host you consider is saved to unlock."
    echo
    echo -n "no" >| ${SHARED_DIR}/do_you_hold_the_lock_for_the_sno_spoke_cluster_server.txt
    exit 1
  )

  update_base_domain
  update_dns_domains
}

function main {

  setup_aux_host_ssh_access
  extract_and_set_ocp_version
  define_spoke_cluster_name
  set_spoke_cluster_kubeconfig
  hack_spoke_deployment
}

main
