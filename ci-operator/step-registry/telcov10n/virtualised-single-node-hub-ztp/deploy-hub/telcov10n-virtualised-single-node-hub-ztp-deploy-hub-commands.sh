#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function load_env {

  #### Remote Bastion jump host
  export BASTION_VHUB_HOST=${AUX_HOST}

  #### SSH Private key
  export BASTION_VHUB_HOST_SSH_PRI_KEY_FILE="${PWD}/remote-hypervisor-ssh-privkey"
  cat /var/run/telcov10n-ansible-group-all/ansible_ssh_private_key > ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  chmod 600 ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}

  #### SSH Public key
  CLUSTER_SSH_PUB_KEY="$(cat /var/run/telcov10n-ansible-group-all/ssh_public_key)"
  export CLUSTER_SSH_PUB_KEY

  #### Pull secret encoded in base64
  CLUSTER_B64_PULL_SECRET="$(cat /var/run/telcov10n-ztp-left-shifting/b64-pull-secret)"
  export CLUSTER_B64_PULL_SECRET

  #### Console password
  VM_PASSWD="$(cat /var/run/telcov10n-ansible-group-all/ansible_password)"
  export VM_PASSWD

  #### Bastion user
  BASTION_VHUB_HOST_USER="$(cat /var/run/telcov10n-ansible-group-all/ansible_user)"
  export BASTION_VHUB_HOST_USER

  #### Network setup
  NETWORK_NIC="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_external_nic)"
  export NETWORK_NIC

  NETWORK_BRIDGE_NAME="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_bridge_name)"
  export NETWORK_BRIDGE_NAME

  NETWORK_BRIDGE_GW_IP="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_bridge_gateway)"
  export NETWORK_BRIDGE_GW_IP

  #### VM
  VM_HUB_ZTP_POOL_PATH="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/libvirt_pool_path)"
  export VM_HUB_ZTP_POOL_PATH

  # shellcheck disable=SC2089
  VM_BOOTSTRAP_IP="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') | ansible.utils.ipaddr('add', 1) }}"
  # shellcheck disable=SC2090
  export VM_BOOTSTRAP_IP

  # shellcheck disable=SC2089
  VM_CONTROL_PLANE_0_IP="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') | ansible.utils.ipaddr('add', 2) }}"
  # shellcheck disable=SC2090
  export VM_CONTROL_PLANE_0_IP

  VM_BOOTSTRAP_MAC="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_bootstrap_mac_address)"
  export VM_BOOTSTRAP_MAC

  VM_CONTROL_PLANE_0_MAC="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_control_plane_0_mac_address)"
  export VM_CONTROL_PLANE_0_MAC

  #### Hub cluster
  CLUSTER_NAME="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_name)"
  export CLUSTER_NAME

  CLUSTER_VERSION="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_version)"
  export CLUSTER_VERSION

  CLUSTER_TAG="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_tag)"
  export CLUSTER_TAG

  CLUSTER_HUB_ZTP_DOMAIN="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/cluster_domain_name)"
  export CLUSTER_HUB_ZTP_DOMAIN

  # shellcheck disable=SC2089
  CLUSTER_HUB_ZTP_API_IP="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') | ansible.utils.ipaddr('add', 3) }}"
  # shellcheck disable=SC2090
  export CLUSTER_HUB_ZTP_API_IP

  # shellcheck disable=SC2089
  CLUSTER_HUB_ZTP_INGRESS_IP="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') | ansible.utils.ipaddr('add', 4) }}"
  # shellcheck disable=SC2090
  export CLUSTER_HUB_ZTP_INGRESS_IP

  CLUSTER_SPOKE_NIC_MAC="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_spoke_mac_address)"
  export CLUSTER_SPOKE_NIC_MAC

  # shellcheck disable=SC2089
  BAREMETAL_SPOKE_IP="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') | ansible.utils.ipaddr('add', 5) }}"
  # shellcheck disable=SC2090
  export BAREMETAL_SPOKE_IP

  SOCKS5_PROXY_PORT="$(cat /var/run/helix92-telcoqe-eng-rdu2-dc-redhat-com/network_socks5_port)"
  export SOCKS5_PROXY_PORT
}

function generate_inventory_file {

  echo "************ telcov10n Generate Ansible inventory file to connect to Bastion host ************"

  load_env

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
          #    name: "{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}"
          #    path: "{{ lookup('ansible.builtin.env', 'VM_HUB_ZTP_POOL_PATH') }}"
          kcli_wrp:
            networks:
            - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
              bridge: true
              bridgename: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
              nic: "{{ lookup('ansible.builtin.env', ' NETWORK_NIC') }}"
              bridge_ip: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') }}"
            clusters:
            - type: openshift
              force_installation: true
              parameters:
                cluster: "{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}"
                version: "{{ lookup('ansible.builtin.env', 'CLUSTER_VERSION') }}"
                tag: "{{ lookup('ansible.builtin.env', 'CLUSTER_TAG') }}"
                domain: "{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}"
                pool: "{{kcli_wrp_libvirt.pool.name}}"
                nets:
                  - "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                keys:
                  - "{{ lookup('ansible.builtin.env', 'CLUSTER_SSH_PUB_KEY') }}"
                ctlplanes: 1
                workers: 0
                memory: 96000
                numcpus: 48
                disks:
                  - 200
                  - 100
                  - 100
                  - 100
                  - 100
                base64_pull_secret: "{{ lookup('ansible.builtin.env', 'CLUSTER_B64_PULL_SECRET') }}"
                api_ip: "${CLUSTER_HUB_ZTP_API_IP}"
                ingress_ip: "${CLUSTER_HUB_ZTP_INGRESS_IP}"
                apps:
                  # - local-storage-operator
                  - lvms-operator
                  - openshift-gitops-operator
                  - advanced-cluster-management
                  - topology-aware-lifecycle-manager
                  - multicluster-engine
                vmrules:
                - vhub-bootstrap:
                    rootpassword: "{{ lookup('ansible.builtin.env', 'VM_PASSWD') }}"
                    nets:
                      - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                        mac: "${VM_BOOTSTRAP_MAC}"
                - vhub-ctlplane-0:
                    rootpassword: "{{ lookup('ansible.builtin.env', 'VM_PASSWD') }}"
                    nets:
                      - name: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"
                        mac: "{{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }}"
          kcli_wrp_credentials:
            clusters_details: ~/.kcli/clusters
            kubeconfig: auth/kubeconfig
            kubeadmin_password: auth/kubeadmin-password
          kcli_wrp_dnsmasq:
            use_nm_plugin: true
            drop_in_files:
              - path: /etc/NetworkManager/dnsmasq.d/70-{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}.conf
                content: |
                  # /etc/NetworkManager/dnsmasq.d/70-{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}.conf

                  log-dhcp
                  log-queries
                  # log-facility=/var/log/dnsmasq.log
                  strict-order

                  server=10.11.5.160
                  server=10.2.70.215

                  # except-interface=lo # <--- To check local resolves
                  interface="{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}"

                  listen-address=127.0.0.1,{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') }}

                  dhcp-range={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('network') }},static
                  dhcp-no-override
                  # dhcp-authoritative <---- No needed
                  # dhcp-lease-max=253

                  # Bridge setup:
                  # dhcp-option=121,{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('subnet') }}
                  dhcp-host={{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_MAC') }},${VM_BOOTSTRAP_IP},{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}-bootstrap.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # Virtualised SNO Hub main NIC
                  dhcp-host={{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_MAC') }},${VM_CONTROL_PLANE_0_IP},{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}-ctlplane-0.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }},set:{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_NAME') }}
                  # SNO Spoke main NIC
                  dhcp-host={{ lookup('ansible.builtin.env', 'CLUSTER_SPOKE_NIC_MAC') }},${BAREMETAL_SPOKE_IP}

                  # This file sets up the local OCP cluster domain and defines some aliases and a wildcard.
                  local=/{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}/
                  # OCP cluster API
                  address=/api.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}/${CLUSTER_HUB_ZTP_API_IP}
                  address=/api-int.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}/${CLUSTER_HUB_ZTP_API_IP}
                  # OCP cluster INGRESS
                  address=/.apps.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_ZTP_DOMAIN') }}/${CLUSTER_HUB_ZTP_INGRESS_IP}
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
                    <masquerade/>
                    <forward/>
                  </zone>
          kcli_wrp_socks5_proxy:
            description: SOCKS5 Proxy Server for ZTP Left shifting
            username: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST_USER') }}"
            host: "{{ lookup('ansible.builtin.env', 'BASTION_VHUB_HOST') }}"
            listen_port: "{{ lookup('ansible.builtin.env', 'SOCKS5_PROXY_PORT') }}"
            ssh_options: "-4"
EOF
}

function install_ansible_collections {
    ansible-galaxy collection install -r requirements.yml
}

function install_virtualised_hub_cluster {

    # cat $inventory_file
    ansible-playbook -i ${inventory_file} playbooks/deploy-virtualised-hub.yml -vvv
}

function verify_virtualised_hub_cluster_installed {
    echo
    echo ${CLUSTER_PROFILE_DIR}
    ls -lRhtr ${CLUSTER_PROFILE_DIR}
    echo
    echo ${SHARED_DIR}
    ls -lRhtr ${SHARED_DIR}
    echo
    grep -HiIn 'server:\|proxy-url:' ${SHARED_DIR}/kubeconfig
    echo
    sc="$(oc --kubeconfig ${SHARED_DIR}/kubeconfig get sc -oname | head -1)"
    oc --kubeconfig ${SHARED_DIR}/kubeconfig annotate ${sc} storageclass.kubernetes.io/is-default-class=true --overwrite
    echo
    oc --kubeconfig ${SHARED_DIR}/kubeconfig get nodes,sc -owide
}

function main {

    echo "Runing Prow script..."

    install_ansible_collections
    generate_inventory_file
    install_virtualised_hub_cluster
    set -x
    verify_virtualised_hub_cluster_installed
}

# function pr_debug_mode_waiting {

#   ext_code=$? ; [ $ext_code -eq 0 ] && return

#   echo "################################################################################"
#   echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
#   echo "################################################################################"

#   TZ=UTC
#   END_TIME=$(date -d "${TIMEOUT}" +%s)
#   debug_done=/tmp/debug.done

#   while sleep 1m; do

#     test -f ${debug_done} && break
#     echo
#     echo "-------------------------------------------------------------------"
#     echo "'${debug_done}' not found. Debugging can continue... "
#     now=$(date +%s)
#     if [ ${END_TIME} -lt ${now} ] ; then
#       echo "Time out reached. Exiting by timeout..."
#       break
#     else
#       echo "Now:     $(date -d @${now})"
#       echo "Timeout: $(date -d @${END_TIME})"
#     fi
#     echo "Note: To exit from debug mode before the timeout is reached,"
#     echo "just run the following command from the POD Terminal:"
#     echo "$ touch ${debug_done}"

#   done

#   echo
#   echo "Exiting from Pull Request debug mode..."
# }

# trap pr_debug_mode_waiting EXIT
main