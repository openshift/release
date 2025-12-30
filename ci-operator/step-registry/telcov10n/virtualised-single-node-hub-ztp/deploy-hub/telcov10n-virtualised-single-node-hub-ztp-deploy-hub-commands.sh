#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function get_hub_id_and_updated_pool {

  local ts
  ts=${1} ; shift

  local timeout
  timeout="$(date -u -d "${MAX_HUB_DEPLOYMENT_TIMEOUT}" +%s%N)"

  set -x
  # Determine if there is any free slot to deploy a new vhub
  pool_limit=$(jq -r '.pool_limit' <<<"${hub_pool_state}")
  pool_count=$(jq -r '.pool | length' <<<"${hub_pool_state}")

  if [ ${pool_count} -lt ${pool_limit} ]; then
    id=${pool_count}
    hub_pool_state=$(jq -c '.pool += [
        {
          "timeout": "'${timeout}'",
          "hub_id": "'${id}'",
          "state": "installing"
        }
      ]' <<<"${hub_pool_state}")
  else
    # Select the older being installed which timout
    # has been reached to be reinstalled since
    # it probably means that the installation
    # failed.
    id=$(jq -r --arg ts "${ts}" '
      [ .pool[]
      | select(.state == "installing" and (($ts | tonumber) > (.timeout | tonumber))) ]
      | sort_by(.timeout)
      | first.hub_id
      ' <<<"${hub_pool_state}")
    if [ "${id}" == "null" ]; then
      # Select the older one to be reinstalled
      id=$(jq -r '
        [ .pool[] ]
        | sort_by(.timeout)
        | first.hub_id
        ' <<<"${hub_pool_state}")
    fi

    hub_pool_state=$(jq -c --arg timeout "${timeout}" --arg id "${id}" '
      (.pool[] | select(.hub_id == $id))
      |= (.timeout = $timeout | .state = "installing")
      ' <<<"${hub_pool_state}")
  fi
  set +x

  echo "${id} ${hub_pool_state}"
  return 0
}

function select_vhub_to_use {

  echo "************ telcov10n Selecting virtualised SNO Hub cluster to use ************"

  local virtualized_hub_pool_fname
  virtualized_hub_pool_fname=${1} ; shift
  local virtualised_hub_pool_limit
  virtualised_hub_pool_limit=${1} ; shift
  local ts
  ts=${1} ; shift

  echo
  set -x
  # Initialize the hub pool state from the remote file, or create a new one if it doesn't exist.
  # Note: pool_limit is zero-padded to 3 digits (e.g., "002") for consistent string comparison.
  hub_pool_state=$(
      timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" cat ${virtualized_hub_pool_fname} || \
      echo '{
        "pool_limit": "'"$(printf '%03d' "${virtualised_hub_pool_limit}")"'",
        "pool": []
      }' | jq -c)
  ret=$(get_hub_id_and_updated_pool ${ts} ${hub_pool_state})
  hub_id_selected=$(echo $ret | cut -d' ' -f1)
  hub_pool_state=$(echo $ret | cut -d' ' -f2)
  set +x
  echo "---------------------"
  echo ${hub_pool_state} | jq
  echo "---------------------"
  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "'${hub_pool_state}'" "${virtualized_hub_pool_fname}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
echo "${1}" >| ${2}
EOF

  # 3 IPs are needed to Hub plus 1 extra for a Spoke, so that the hubs would use:
  # .1 to .3, then use .4 for a Spoke. The next one would be .5 to .7 and .9 for the next
  # Spoke and so on.
  network_address_shift_for_selected_virtualised_hub=$(( 4 * ${hub_id_selected} + 1 ))
  echo -n "${hub_id_selected} ${virtualized_hub_pool_fname}" >| ${SHARED_DIR}/hub_pool_info.txt
  set +x
  echo
}

function select_virtualised_sno_hub {

  echo "************ telcov10n Locking virtualised SNO Hub selection ************"

  local ssh_key
  ssh_key="${1}" ; shift

  setup_aux_host_ssh_access "${ssh_key}"

  local ts

  local virtualized_hub_pool_filename
  virtualized_hub_pool_filename="/var/run/lock/ztp-virtualised-hub-pool/virtualised-hub-pool.json"

  local lock_filename
  lock_filename="${virtualized_hub_pool_filename}.lock"

  virtualised_hub_pool_limit=$(cat ${bastion_settings}/max_available_virtualised_sno_hubs)
  for ((attempts = 0 ; attempts < ${max_attempts:=5} ; attempts++)); do
    ts=$(date -u +%s%N)
    echo "Locking ${lock_filename} shared file... [${attempts/${max_attempts}}]"
    try_to_lock_host "${AUX_HOST}" "${lock_filename}" "${ts}" "${lock_timeout:="120"}"
    if [[ "$(check_the_host_was_locked "${AUX_HOST}" "${lock_filename}" "${ts}")" == "locked" ]] ; then
      select_vhub_to_use "${virtualized_hub_pool_filename}" "${virtualised_hub_pool_limit}" "${ts}"
      return 0
    fi
    set -x
    sleep 1m
    set +x
  done

  echo
  echo "[FATAL] Dead-Lock condition while trying to install a new virtualised Hub cluster!!!"
  echo "For manual clean up, check out /var/run/lock/ztp-virtualised-hub-pool/*.lock folder in your bastion host"
  echo "and remove the ${lock_filename} file"
  echo
  exit 1
}

function generate_mac_addresses {

  local hub_id_selected
  hub_id_selected=${1} ; shift

  network_ipv4_subnet="$(cat ${bastion_settings}/network_ipv4_subnet)"

  oct_net="$(echo ${network_ipv4_subnet} | cut -d'.' -f3)"
  hex_net="$(printf '%02x:%01x' ${oct_net} ${hub_id_selected})"

  VM_BOOTSTRAP_MAC="7e:1c:0b:10:${hex_net}1"
  export VM_BOOTSTRAP_MAC

  VM_CONTROL_PLANE_0_MAC="7e:1c:0b:10:${hex_net}2"
  export VM_CONTROL_PLANE_0_MAC
}

function load_env {

  bastion_settings="/var/run/telcov10n/helix92-telcoqe-eng-rdu2-dc-redhat-com"

  #### Remote Bastion jump host
  export BASTION_VHUB_HOST=${AUX_HOST}

  #### SSH Private key
  export BASTION_VHUB_HOST_SSH_PRI_KEY_FILE="${PWD}/remote-hypervisor-ssh-privkey"
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key > ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  chmod 600 ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}

  select_virtualised_sno_hub "${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}"

  #### SSH Public key
  CLUSTER_SSH_PUB_KEY="$(cat /var/run/telcov10n/ansible-group-all/ssh_public_key)"
  export CLUSTER_SSH_PUB_KEY

  #### Pull secret encoded in base64
  # CLUSTER_B64_PULL_SECRET="$(cat /var/run/telcov10n/ztp-left-shifting/b64-pull-secret)"
  CLUSTER_B64_PULL_SECRET="$(cat ${CLUSTER_PROFILE_DIR}/pull-secret | base64 -w 0)"
  export CLUSTER_B64_PULL_SECRET

  #### Bastion user
  BASTION_VHUB_HOST_USER="$(cat /var/run/telcov10n/ansible-group-all/ansible_user)"
  export BASTION_VHUB_HOST_USER

  #### Network setup
  NETWORK_NIC="$(cat ${bastion_settings}/network_external_nic)"
  export NETWORK_NIC

  NETWORK_BRIDGE_NAME="$(cat ${bastion_settings}/network_bridge_name)"
  export NETWORK_BRIDGE_NAME

  NETWORK_IPv4_SUBNET="$(cat ${bastion_settings}/network_ipv4_subnet)"
  export NETWORK_IPv4_SUBNET

  ipv4_offset="20"
  ipv6_offset="$(cat ${bastion_settings}/network_ipv6_offset)"
  NETWORK_IPv6_SUBNET="$(cat ${bastion_settings}/network_ipv6_subnet)"
  export NETWORK_IPv6_SUBNET

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_CIDR_IPv4="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('$ipv4_offset') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_CIDR_IPv4
  # shellcheck disable=SC2089
  NETWORK_BRIDGE_CIDR_IPv6="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipaddr('$(($ipv6_offset + 32))') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_CIDR_IPv6

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_IPv4="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('$ipv4_offset') | ansible.utils.ipv4('address') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_IPv4
  # shellcheck disable=SC2089
  NETWORK_BRIDGE_IPv6="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipaddr('$(($ipv6_offset + 32))') | ansible.utils.ipv6('address') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_IPv6

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_IPv4_SUBNET="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipv4('network') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_IPv4_SUBNET
  # shellcheck disable=SC2089
  NETWORK_BRIDGE_IPv6_SUBNET="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipv6('network') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_IPv6_SUBNET

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_IPv4_NET_MASK="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipv4('netmask') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_IPv4_NET_MASK

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_GW_IPv4="$(cat ${bastion_settings}/network_ipv4_gateway)"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_GW_IPv4
  # shellcheck disable=SC2089
  NETWORK_BRIDGE_GW_IPv6="$(cat ${bastion_settings}/network_ipv6_gateway)"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_GW_IPv6

  #### DNS

  # shellcheck disable=SC2089
  NETWORK_BRIDGE_BASE_DOMAIN="{{ lookup('ansible.builtin.env', 'CLUSTER_BASE_DOMAIN') }}"
  # shellcheck disable=SC2090
  export NETWORK_BRIDGE_BASE_DOMAIN

  # shellcheck disable=SC2089
  DNS_SERVER_1="$(cat ${bastion_settings}/dns_server_1)"
  # shellcheck disable=SC2090
  export DNS_SERVER_1

  # shellcheck disable=SC2089
  DNS_SERVER_2="$(cat ${bastion_settings}/dns_server_2)"
  # shellcheck disable=SC2090
  export DNS_SERVER_2

  #### VM
  VM_HUB_ZTP_POOL_PATH="$(cat ${bastion_settings}/libvirt_pool_path)"
  export VM_HUB_ZTP_POOL_PATH

  #### Resources details
  VM_CPUS="$(cat ${bastion_settings}/vm_cpus)"
  export VM_CPUS

  VM_MEM="$(cat ${bastion_settings}/vm_ram)"
  export VM_MEM

  vm_disk_list="$(cat ${bastion_settings}/vm_disks)"
  VM_DISKS="$(echo ${vm_disk_list} | jq --compact-output)"
  export VM_DISKS

  #### Console password
  VM_PASSWD="$(cat /var/run/telcov10n/ansible-group-all/ansible_password)"
  export VM_PASSWD

  # shellcheck disable=SC2089
  VM_BOOTSTRAP_IPv4="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('$(($ipv4_offset + 0 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv4('address') }}"
  # shellcheck disable=SC2090
  export VM_BOOTSTRAP_IPv4
  # shellcheck disable=SC2089
  VM_BOOTSTRAP_IPv6="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipaddr('$(($ipv6_offset + 32 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv6('address') }}"
  # shellcheck disable=SC2090
  export VM_BOOTSTRAP_IPv6

  # shellcheck disable=SC2089
  VM_CONTROL_PLANE_0_IPv4="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('$(($ipv4_offset + 1 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv4('address') }}"
  # shellcheck disable=SC2090
  export VM_CONTROL_PLANE_0_IPv4
  # shellcheck disable=SC2089
  VM_CONTROL_PLANE_0_IPv6="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipaddr('$(($ipv6_offset + 33 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv6('address') }}"
  # shellcheck disable=SC2090
  export VM_CONTROL_PLANE_0_IPv6

  generate_mac_addresses "${hub_id_selected}"

  #### Hub cluster
  HUB_CLUSTER_NAME="sno-vhub-${hub_id_selected}"
  export HUB_CLUSTER_NAME

  HUB_CLUSTER_VERSION="stable"
  export HUB_CLUSTER_VERSION

  set -x
  if [ -n "${PULL_NUMBER:-}" ] && [ -n "${SET_SPECIFIC_RELEASE_IMAGE}" ]; then
    rel_img="${SET_SPECIFIC_RELEASE_IMAGE}"
  else
    rel_img=${RELEASE_IMAGE_LATEST}
  fi
  HUB_CLUSTER_TAG="$(extract_cluster_image_set_reference ${rel_img} ${CLUSTER_PROFILE_DIR}/pull-secret)"
  set +x
  export HUB_CLUSTER_TAG

  CLUSTER_BASE_DOMAIN="$(cat ${bastion_settings}/cluster_domain_name)"
  export CLUSTER_BASE_DOMAIN

  # shellcheck disable=SC2089
  HUB_CLUSTER_API_IPv4="{{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('$(($ipv4_offset + 2 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv4('address') }}"
  # shellcheck disable=SC2090
  export HUB_CLUSTER_API_IPv4
  # shellcheck disable=SC2089
  HUB_CLUSTER_API_IPv6="{{ lookup('ansible.builtin.env', 'NETWORK_IPv6_SUBNET') | ansible.utils.ipaddr('$(($ipv6_offset + 34 + $network_address_shift_for_selected_virtualised_hub))') | ansible.utils.ipv6('address') }}"
  # shellcheck disable=SC2090
  export HUB_CLUSTER_API_IPv6

  # shellcheck disable=SC2089
  HUB_CLUSTER_INGRESS_IPv4="${HUB_CLUSTER_API_IPv4}"
  # shellcheck disable=SC2090
  export HUB_CLUSTER_INGRESS_IPv4
  # shellcheck disable=SC2089
  HUB_CLUSTER_INGRESS_IPv6="${HUB_CLUSTER_API_IPv6}"
  # shellcheck disable=SC2090
  export HUB_CLUSTER_INGRESS_IPv6

  # shellcheck disable=SC2089
  set -x
  HUB_CLUSTER_OPERATORS="$(echo ${OPERATORS} | jq --compact-output '[.[].name]')"
  set +x
  # shellcheck disable=SC2090
  export HUB_CLUSTER_OPERATORS

  #### Proxy access
  SOCKS5_PROXY_PORT="${SOCKS5_PROXY##*:}"
  export SOCKS5_PROXY_PORT
}

function generate_inventory_file {

  echo "************ telcov10n Generate Ansible inventory file to connect to Bastion host ************"

  inventory_file="${PWD}/bastion-vhub-node-inventory.yml"
  cat <<EOF >| $inventory_file
all:
  children:
    prow_bastion:
      hosts:
        bastion-vhub-node:
          ansible_host: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST') }}"
          ansible_user: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST_USER') }}"
          ansible_ssh_private_key_file: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST_SSH_PRI_KEY_FILE') }}"
          ansible_ssh_common_args: ' \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ServerAliveInterval=90 \
            -o LogLevel=ERROR'
          # kcli_wrp_install_depencencies: true
          # kcli_wrp_oc:
          #   url: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
          #   dest: /usr/local/bin
          # kcli_wrp_libvirt:
          #  pool:
          #    name: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}"
          #    path: "{{ lookup('ansible.builtin.env', 'VM_HUB_ZTP_POOL_PATH') }}"
          kcli_wrp:
            # networks:
            # - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
            #   bridge: true
            #   nic: "{{ lookup('ansible.builtin.env', ' NETWORK_NIC') }}"
            #   bridge_cidr_ipv4: "${NETWORK_BRIDGE_CIDR_IPv4}"
            #   bridge_gw4: "${NETWORK_BRIDGE_GW_IPv4}"
            #   bridge_dns_ipv4:
            #     - "${DNS_SERVER_1}"
            #     - "${DNS_SERVER_2}"
            #   bridge_cidr_ipv6: "${NETWORK_BRIDGE_CIDR_IPv6}"
            #   bridge_gw6: "${NETWORK_BRIDGE_GW_IPv6}"
            clusters:
            - type: openshift
              force_installation: true
              parameters:
                cluster: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}"
                version: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_VERSION') }}"
                tag: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_TAG') }}"
                domain: "${NETWORK_BRIDGE_BASE_DOMAIN}"
                pool: "{{kcli_wrp_libvirt.pool.name}}"
                nets:
                  - "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                keys:
                  - "{{ lookup('ansible.builtin.env', 'CLUSTER_SSH_PUB_KEY') }}"
                ctlplanes: 1
                workers: 0
                memory: ${VM_MEM}
                numcpus: ${VM_CPUS}
                disks: ${VM_DISKS}
                base64_pull_secret: "{{ lookup('ansible.builtin.env', 'CLUSTER_B64_PULL_SECRET') }}"
                api_ip: "${HUB_CLUSTER_API_IPv4}"
                # ingress_ip: "${HUB_CLUSTER_INGRESS_IPv4}"
                # dual_api_ip: "${HUB_CLUSTER_API_IPv6}"
                # ingress_ip: "${HUB_CLUSTER_INGRESS_IPv6}"
                # apps: ${HUB_CLUSTER_OPERATORS}
                ignore_hosts: true
                vmrules:
                - ${HUB_CLUSTER_NAME}-bootstrap:
                    rootpassword: "{{ lookup('ansible.builtin.env', 'VM_PASSWD') }}"
                    nets:
                      - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                        mac: "{{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_MAC') }}"
                        # ip: "${VM_BOOTSTRAP_IPv4}"
                        # mask: "${NETWORK_BRIDGE_IPv4_NET_MASK}"
                        # gateway: "${NETWORK_BRIDGE_GW_IPv4}"
                        # domain: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-bootstrap.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                - ${HUB_CLUSTER_NAME}-ctlplane-0:
                    rootpassword: "{{ lookup('ansible.builtin.env', 'VM_PASSWD') }}"
                    nets:
                      - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                        mac: "{{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }}"
                        # ip: "${VM_CONTROL_PLANE_0_IPv4}"
                        # mask: "${NETWORK_BRIDGE_IPv4_NET_MASK}"
                        # gateway: "${NETWORK_BRIDGE_GW_IPv4}"
                        # domain: "{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-ctlplane-0.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
          kcli_wrp_credentials:
            clusters_details: ~/.kcli/clusters
            kubeconfig: auth/kubeconfig
            kubeadmin_password: auth/kubeadmin-password
          kcli_wrp_dnsmasq:
            use_nm_plugin: true
            drop_in_files:
              - path: /etc/NetworkManager/dnsmasq.d/70-sno-hub-with-mac_${VM_CONTROL_PLANE_0_MAC//:/-}.${NETWORK_BRIDGE_BASE_DOMAIN}.conf
                content: |
                  # /etc/NetworkManager/dnsmasq.d/70-sno-spoke-with-mac_${VM_CONTROL_PLANE_0_MAC//:/-}.${NETWORK_BRIDGE_BASE_DOMAIN}.conf

                  domain=${NETWORK_BRIDGE_BASE_DOMAIN}
                  domain-needed
                  bogus-priv
                  expand-hosts

                  log-dhcp
                  log-queries
                  # log-facility=/var/log/dnsmasq.log

                  server=${DNS_SERVER_1}
                  server=${DNS_SERVER_2}

                  # except-interface=lo # <--- To check local resolves
                  interface={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}

                  listen-address=127.0.0.1,${NETWORK_BRIDGE_IPv4}
                  # listen-address=127.0.0.1,${NETWORK_BRIDGE_IPv4},${NETWORK_BRIDGE_IPv6}

                  ########################################
                  # DHCP IPv4
                  ########################################

                  # dhcp-range={{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipaddr('network') }},static,4h
                  #            {{ lookup('ansible.builtin.env', 'NETWORK_IPv4_SUBNET') | ansible.utils.ipv4('network') }}"
                  dhcp-range=${NETWORK_BRIDGE_IPv4_SUBNET},static,4h
                  dhcp-option={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},option:netmask,${NETWORK_BRIDGE_IPv4_NET_MASK}
                  dhcp-option={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},option:router,${NETWORK_BRIDGE_GW_IPv4}
                  dhcp-option={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},option:dns-server,${NETWORK_BRIDGE_IPv4}
                  dhcp-option={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},option:ntp-server,${NETWORK_BRIDGE_IPv4}
                  dhcp-option={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},option:domain-search,${NETWORK_BRIDGE_BASE_DOMAIN}
                  # dhcp-no-override

                  ########################################
                  # DHCP IPv6
                  ########################################

                  # dhcp-range={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},${NETWORK_BRIDGE_IPv6_SUBNET},ra-stateless,ra-names
                  # # dhcp-range={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }},${NETWORK_BRIDGE_IPv6_SUBNET},static,64,4h
                  # dhcp-option=option6:dns-server,[${NETWORK_BRIDGE_IPv6}]
                  # # enable-ra
                  # # dhcp-authoritative
                  # strict-order

                  ########################################
                  # IP reserved
                  ########################################

                  # Bridge setup:
                  dhcp-host={{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_MAC') }},${VM_BOOTSTRAP_IPv4},{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-bootstrap.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # dhcp-host=id:00:03:00:01:{{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_MAC') }},[${VM_BOOTSTRAP_IPv6}],{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-bootstrap.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # dhcp-host={{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_MAC') }},${VM_BOOTSTRAP_IPv4},[${VM_BOOTSTRAP_IPv6}],{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-bootstrap.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # Virtualised SNO Hub main NIC
                  dhcp-host={{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }},${VM_CONTROL_PLANE_0_IPv4},{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-ctlplane-0.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # dhcp-host=id:00:03:00:01:{{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }},[${VM_CONTROL_PLANE_0_IPv6}],{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-ctlplane-0.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # dhcp-host={{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }},${VM_CONTROL_PLANE_0_IPv4},[${VM_CONTROL_PLANE_0_IPv6}],{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}-ctlplane-0.${NETWORK_BRIDGE_BASE_DOMAIN},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}

                  ########################################
                  # DNS entries
                  ########################################

                  # This file sets up the local OCP cluster domain and defines some aliases and a wildcard.
                  # local=/{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/
                  local=/${NETWORK_BRIDGE_BASE_DOMAIN}/
                  #
                  # OCP HUB cluster
                  #
                  # OCP HUB cluster API
                  address=/api.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_API_IPv4}
                  address=/api-int.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_API_IPv4}
                  # address=/api.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_API_IPv6}
                  # address=/api-int.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_API_IPv6}
                  # OCP HUB cluster INGRESS
                  address=/.apps.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_INGRESS_IPv4}
                  # address=/.apps.{{ lookup('ansible.builtin.env', 'HUB_CLUSTER_NAME') }}.${NETWORK_BRIDGE_BASE_DOMAIN}/${HUB_CLUSTER_INGRESS_IPv6}
          kcli_wrp_firewalld:
            zone_files:
              - path: /etc/firewalld/zones/public.xml
                content: |
                  <?xml version="1.0" encoding="utf-8"?>
                  <zone>
                    <short>Public</short>
                    <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
                    <service name="ssh"/>
                    <service name="dhcpv6-client"/>
                    <service name="cockpit"/>
                    <service name="dhcp"/>
                    <service name="dns"/>
                    <service name="https"/>
                    <port port="{{ lookup('ansible.builtin.env', 'SOCKS5_PROXY_PORT') }}" protocol="tcp"/>
                    <forward/>
                  </zone>
          kcli_wrp_socks5_proxy:
            description: SOCKS5 Proxy Server for ZTP Left shifting
            username: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST_USER') }}"
            host: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST') }}"
            listen_port: "{{ lookup('ansible.builtin.env', 'SOCKS5_PROXY_PORT') }}"
            ssh_options: "-4"
EOF

  echo "--------- Inventory File ---------------------"
  echo "${inventory_file}"
  echo "----------------------------------------------"
  sed \
    -e 's/base64_pull_secret: .*/base64_pull_secret: REDACTED.../g' \
    -e 's/rootpassword: .*/rootpassword: REDACTED.../' \
    $inventory_file
  echo "----------------------------------------------"
  echo
}

function install_ansible_collections {
    ansible-galaxy collection install -r requirements.yml
}

function generate_pull_secret {

  if [ -f $CLUSTER_PROFILE_DIR/pull-secret ]; then

    echo "************ telcov10n Generate Pull Secret from all available sources ************"

    ps_base=$(mktemp)
    echo ${CLUSTER_B64_PULL_SECRET} | base64 -d > ${ps_base}

    CLUSTER_B64_PULL_SECRET=$(jq -s '.[0] * .[1]' \
      ${ps_base} \
      $CLUSTER_PROFILE_DIR/pull-secret \
      | base64 -w 0)

    # echo ${CLUSTER_B64_PULL_SECRET} | base64 -d > ${ps_base}.merged
    rm -f ${ps_base}
  fi
}

function install_virtualised_hub_cluster {

  local ansible_verbosity

  set -x
  ansible_verbosity="$(cat "${bastion_settings}/ansible_verbosity" || echo -n)"
  ansible-playbook -i ${inventory_file} playbooks/deploy-virtualised-hub.yml \
    --extra-vars hide_ansible_logs="$([[ "$(cat "${bastion_settings}/show_ansible_logs" || echo "false")" == "false" ]] && echo "true" || echo "false")" \
    ${ansible_verbosity}
  set +x
}

function verify_virtualised_hub_cluster_installed {
    echo
    echo ${CLUSTER_PROFILE_DIR}
    ls -lRhtr ${CLUSTER_PROFILE_DIR}
    echo
    echo ${SHARED_DIR}
    ls -lRhtr ${SHARED_DIR}
    echo
    set -x
    grep -HiIn 'server:\|proxy-url:' ${SHARED_DIR}/kubeconfig
    set +x
    echo
    set -x
    oc --kubeconfig ${SHARED_DIR}/kubeconfig get nodes -owide
    set +x
}

function main {

  echo "Runing Prow script..."

  load_env

  install_ansible_collections
  generate_pull_secret
  generate_inventory_file
  install_virtualised_hub_cluster
  verify_virtualised_hub_cluster_installed
}

function pr_debug_mode_waiting {

  ext_code=$? ; [ $ext_code -eq 0 ] && return

  set -x
  [ -n "${inventory_file:-}" ] && \
    cp -v $inventory_file "${SHARED_DIR}/$(basename ${inventory_file})"
  env > "${SHARED_DIR}/$(basename ${inventory_file}).env"

  [ -z "${PULL_NUMBER:-}" ] && return
  set +x

  echo "################################################################################"
  echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "${DEBUGGING_TIMEOUT}" +%s)
  debug_done=/tmp/debug.done

  while sleep 1m; do

    test -f ${debug_done} && break
    echo
    echo "-------------------------------------------------------------------"
    echo "'${debug_done}' not found. Debugging can continue... "
    now=$(date +%s)
    if [ ${END_TIME} -lt ${now} ] ; then
      echo "Time out reached. Exiting by timeout..."
      break
    else
      echo "Now:     $(date -d @${now})"
      echo "Timeout: $(date -d @${END_TIME})"
    fi
    echo "Note: To exit from debug mode before the timeout is reached,"
    echo "just run the following command from the POD Terminal:"
    echo "$ touch ${debug_done}"

  done

  echo
  echo "Exiting from Pull Request debug mode..."
}

trap pr_debug_mode_waiting EXIT
main
# exit 0

# virtualised_hub_pool_limit=2
# ts="1744299070915786694"

# hub_pool_state=$(
#     echo '{
#       "pool_limit": "'${virtualised_hub_pool_limit}'",
#       "pool": [
#         {
#           "ts": "'${ts}'",
#           "timeout": "'$(date -u -d "${MAX_HUB_DEPLOYMENT_TIMEOUT}" +%s%N)'",
#           "hub_id": "0",
#           "state": "installing"
#         }
#       ]
#     }' | jq -c)

# echo "---------------------"
# echo ${hub_pool_state} | jq
# echo "---------------------"


# for (( idx=0; idx < 2; idx++ ));do
#   ts=$(date -u +%s%N)
#   ret=$(get_hub_id_and_updated_pool "${ts}" "${hub_pool_state}")
#   id=$(echo $ret | cut -d' ' -f1)
#   hub_pool_state=$(echo $ret | cut -d' ' -f2)

#   echo
#   echo "RET: ${ret}"
#   echo

#   echo "---------------------"
#   echo ${hub_pool_state} | jq
#   echo "---------------------"
# done