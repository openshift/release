#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function load_env {

  export BASTION_VHUB_HOST=${AUX_HOST}

  ####
  # export BASTION_VHUB_HOST_SSH_PRI_KEY_FILE="${PWD}/remote-hypervisor-ssh-b64-privkey"
  # cat /var/run/telcov10n-ztp-left-shifting/remote-hypervisor-ssh-b64-privkey | base64 -d > ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  # chmod 600 ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  export BASTION_VHUB_HOST_SSH_PRI_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-key"

  #export CLUSTER_SSH_PUB_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDm9hb6iTZJypEmzg4IZ767ze60UGhBWnjPXhovWVB7uKputdLzZhmlo36ifkXr/DTk8NGm47r6kXmz9NAF0pDHa5jX6yJFnhS4z5NY/mzsUX41gwiqBKYHgdp/KE1ylE8mbNon5ZpaaGvb876myjjPjPwWsD8hvXZirA5Q8TfDb/Pvgy1dhVH/uN05Ip1vVsp+bFGMPUJVWVUy/Eby5xW6OJv+FBOQq4nu6tslDZlHYXX2TSGrlW4x0i/oQMpKu/Y8ygAdjWqmAy6UBcho1nNWy15cp0jI5Fhjze171vSWZLAqJY+eFcL2kt/09RnY+MXyY/tIf+qNMyBE2Qltigah"
  export CLUSTER_SSH_PUB_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKyo2CxXHRP3Q5Ay0ZOlxCNSuH3xCSB68exLwE9b1fbvnzHQLfczM2oMySmEKmAN/l+mDSbrXVqx5Aa+Q76nmPK31ALbwCw94dd6A5IeM6t9PguWiodosXXccm7CgAh61+CIM6FkbrSw8mEFlUd/5LqQoi5xe3Y4ioYinXgDRIcN2aNaKr/BDGyMsnn4l9w/gOf+pMRQdqOa/cctKEt7SzMtnONNYKTf9hV2XQegVYNFgbmVKJvog3BR9jm8pAlE8mcGtn1QNsnNcXVqXRDKj/Sx1B7YfS631PVUX6Wpt2r2nYBwvUprmvh2Iqs/qBpG38kKe4afXRG9RNX65/ETiS/EdFta+q96Sbk/GOUPcn+NbNVwDFTKBdP0c88oPtp13vF78Ggdprx+uoUj6NAhb/bsnm4B1uKv71c++e+QqfFfjTcmtaCoZDRBHNT0FW+B/HLBhBQAV0qseSnZ69HYHgup0aKAbIwmsW5yqFewdU0CIPfgbPM06lo3/YkIunDf2IeEjzjz8LOtNmj+qiEsOU4xbMhbt9aeE4e6W6sC2FQrgqq2KFI27IvOeJSq6JAoXEIl+A5ZEhmjIKBrgucCZeMINB2c07354jGocq1A5d/oMc3YDoCc+HqDOCvugfxi8gQh1rKSrhZkOsvQTSzaLqpjLZEQ3IQU5oeRrKHPfDEQ== openshift-qe"

  ####
  CLUSTER_B64_PULL_SECRET="$(cat /var/run/telcov10n-ztp-left-shifting/b64-pull-secret)"
  export CLUSTER_B64_PULL_SECRET

  ####
  VM_PASSWD="$(cat /var/run/telcov10n-ztp-left-shifting/cluster-admin-pass)"
  export VM_PASSWD

  ####
  export BASTION_VHUB_HOST_USER="telcov10n"
  export VM_BOOTSTRAP_IP="192.168.80.100"
  export VM_CONTROL_PLANE_0_IP="192.168.80.10"
  export NETWORK_NIC="eno12399"
  export NETWORK_BRIDGE_NAME="baremetal"
  export NETWORK_BRIDGE_GW_IP="192.168.80.1/22"
  export CLUSTER_NAME="vhub"
  export CLUSTER_ZTP_IN_PROW_POOL_PATH="/var/lib/libvirt/images"
  export CLUSTER_VERSION="stable"
  export CLUSTER_TAG="4.17"
  export CLUSTER_ZTP_IN_PROW_DOMAIN="ztp-left-shifting.kpi.telco.lab"
  export CLUSTER_ZTP_IN_PROW_API_IP="192.168.80.5"
  export CLUSTER_ZTP_IN_PROW_INGRESS_IP="192.168.80.6"
  export CLUSTER_BRIDGE_NIC_MAC_BOOTSTRAP="cc:a4:de:aa:aa:01"
  export CLUSTER_HUB_NIC_MAC="cc:a4:de:aa:aa:10"
  export CLUSTER_SPOKE_NIC_MAC="50:7c:6f:5c:47:8c"
  export BAREMETAL_SPOKE="192.168.80.20"
  export SOCKS5_PROXY_PORT="3124"
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
          #    path: "{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_POOL_PATH') }}"
          kcli_wrp:
            networks:
            - name: "{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"
              bridge: true
              bridgename: "{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"
              nic: eno12399
              bridge_ip: "{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') }}"
            clusters:
            - type: openshift
              force_installation: true
              parameters:
                cluster: "{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}"
                version: "{{ lookup('ansible.builtin.env', 'CLUSTER_VERSION') }}"
                tag: "{{ lookup('ansible.builtin.env', 'CLUSTER_TAG') }}"
                domain: "{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}"
                pool: "{{kcli_wrp_libvirt.pool.name}}"
                nets:
                  - "{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"
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
                api_ip: "{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_API_IP') }}"
                ingress_ip: "{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_INGRESS_IP') }}"
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
                      - name: "{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"
                        mac: "{{ lookup('ansible.builtin.env', 'CLUSTER_BRIDGE_NIC_MAC_BOOTSTRAP') }}"
                - vhub-ctlplane-0:
                    rootpassword: "{{ lookup('ansible.builtin.env', 'VM_PASSWD') }}"
                    nets:
                      - name: "{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"
                        mac: "{{ lookup('ansible.builtin.env', 'CLUSTER_HUB_NIC_MAC') }}"
          kcli_wrp_credentials:
            clusters_details: ~/.kcli/clusters
            kubeconfig: auth/kubeconfig
            kubeadmin_password: auth/kubeadmin-password
          kcli_wrp_dnsmasq:
            use_nm_plugin: true
            drop_in_files:
              - path: /etc/NetworkManager/dnsmasq.d/70-{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}.conf
                content: |
                  # /etc/NetworkManager/dnsmasq.d/70-{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}.conf
                  
                  log-dhcp
                  log-queries
                  # log-facility=/var/log/dnsmasq.log
                  strict-order

                  server=10.11.5.160
                  server=10.2.70.215

                  # except-interface=lo # <--- To check local resolves
                  interface="{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}"

                  listen-address=127.0.0.1,{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('address') }}

                  dhcp-range={{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('network') }},static
                  dhcp-no-override
                  # dhcp-authoritative <---- No needed
                  # dhcp-lease-max=253

                  # Bridge setup:
                  # dhcp-option=121,{{ lookup('ansible.builtin.env', 'NETWORK_BRIDGE_GW_IP') | ansible.utils.ipaddr('subnet') }}
                  dhcp-host={{ lookup('ansible.builtin.env', 'CLUSTER_BRIDGE_NIC_MAC_BOOTSTRAP') }},{{ lookup('ansible.builtin.env', 'VM_BOOTSTRAP_IP') }},{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}-bootstrap.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }},set:{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}
                  # Virtualised SNO Hub main NIC
                  dhcp-host={{ lookup('ansible.builtin.env', 'CLUSTER_HUB_NIC_MAC') }},{{ lookup('ansible.builtin.env', 'VM_CONTROL_PLANE_0_IP') }},{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}-ctlplane-0.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }},set:{{ lookup('ansible.builtin.env', ' NETWORK_BRIDGE_NAME') }}
                  # SNO Spoke main NIC
                  dhcp-host={{ lookup('ansible.builtin.env', 'CLUSTER_SPOKE_NIC_MAC') }},{{ lookup('ansible.builtin.env', 'BAREMETAL_SPOKE') }}

                  # This file sets up the local OCP cluster domain and defines some aliases and a wildcard.
                  local=/{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}/
                  # OCP cluster API
                  address=/api.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}/{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_API_IP') }}
                  address=/api-int.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}/{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_API_IP') }}
                  # OCP cluster INGRESS
                  address=/.apps.{{ lookup('ansible.builtin.env', 'CLUSTER_NAME') }}.{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_DOMAIN') }}/{{ lookup('ansible.builtin.env', 'CLUSTER_ZTP_IN_PROW_INGRESS_IP') }}
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

function pr_debug_mode_waiting {

  ext_code=$? ; [ $ext_code -eq 0 ] && return

  echo "################################################################################"
  echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "${TIMEOUT}" +%s)
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