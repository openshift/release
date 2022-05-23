#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


export BASTION_SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
echo "RHEL VERSION: '${PLATFORM_VERSION}'"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

declare bastion_private_address
declare bastion_ssh_user
if [ -f "${SHARED_DIR}"/bastion_private_address ] && [ -f "${SHARED_DIR}"/bastion_ssh_user ] ; then
    bastion_private_address=$(< "${SHARED_DIR}"/bastion_private_address)
    bastion_ssh_user=$(< "${SHARED_DIR}"/bastion_ssh_user)
else
    echo "File bastion_private_address or bastion_ssh_user does not exist in SHARED_DIR!"
    exit 1
fi

export BASTION_PRIVATE_ADDRESS=${bastion_private_address}
export BASTION_SSH_USER=${bastion_ssh_user}

cat > scaleup-pre-hook-ssh-tunnel.yaml <<-'EOF'
- name: pre-hook deploy ssh tunnel service in disconnected network env
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false

  vars:
    platform_version: "{{ lookup('env', 'PLATFORM_VERSION') }}"
    major_platform_version: "{{ platform_version[:1] }}"
    bastion_private_address: "{{ lookup('env', 'BASTION_PRIVATE_ADDRESS') }}"
    bastion_ssh_user: "{{ lookup('env', 'BASTION_SSH_USER') }}"
    bastion_ssh_private_key_file: "{{ lookup('env', 'BASTION_SSH_PRIV_KEY_PATH') }}"

  tasks:
  - name: Copy private SSH
    copy:
      src: "{{ bastion_ssh_private_key_file }}"
      dest: "/tmp/id_rsa.pem"
      mode: '0600'

  - name: Create ssh tunnel service
    copy:
      dest: /etc/systemd/system/qe-ssh-tunnel.service
      content: |
        [Unit]
        Description=OpenShift QE SSH Tunnel
        After=network.target syslog.target sshd.service

        [Service]
        Type=simple
        TimeoutStartSec=5m
        ExecStart=/usr/bin/ssh -i /tmp/id_rsa.pem -o ConnectTimeout=60 -o ServerAliveCountMax=2 -o ServerAliveInterval=75 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o VerifyHostKeyDNS=yes -p 22 -ND 5080 {{ bastion_ssh_user }}@{{ bastion_private_address }}
        Restart=always
        RestartSec=30

        [Install]
        WantedBy=multi-user.target

  # Install the SeLinux policy for qe-ssh-tunnel.service on RHEL-8
  - block:
    - name: Copy qe-ssh-tunnel.te
      copy:
        dest: /tmp/qe-ssh-tunnel.te
        content: |


          module qe-ssh-tunnel 1.0;

          require {
                  type unconfined_service_t;
                  type setroubleshootd_t;
                  type user_home_t;
                  type ssh_port_t;
                  type ifconfig_t;
                  type vmware_log_t;
                  type proc_t;
                  type init_t;
                  type groupadd_t;
                  type chkpwd_t;
                  type fsdaemon_t;
                  type ssh_exec_t;
                  type user_devpts_t;
                  type system_dbusd_t;
                  class filesystem getattr;
                  class file { execute execute_no_trans map open read write };
                  class process { noatsecure rlimitinh siginh };
                  class tcp_socket name_connect;
                  class capability net_admin;
                  class chr_file { read write };
          }


          #============= chkpwd_t ==============
          allow chkpwd_t user_devpts_t:chr_file { read write };

          #============= fsdaemon_t ==============
          allow fsdaemon_t self:capability net_admin;

          #============= groupadd_t ==============

          #!!!! This avc is allowed in the current policy
          allow groupadd_t proc_t:filesystem getattr;

          #============= ifconfig_t ==============
          allow ifconfig_t vmware_log_t:file write;

          #============= init_t ==============

          #!!!! This avc can be allowed using the boolean 'domain_can_mmap_files'
          allow init_t ssh_exec_t:file map;
          allow init_t ssh_exec_t:file { execute execute_no_trans open read };

          #!!!! This avc can be allowed using the boolean 'nis_enabled'
          allow init_t ssh_port_t:tcp_socket name_connect;
          allow init_t unconfined_service_t:process siginh;
          allow init_t user_home_t:file { open read };

          #============= setroubleshootd_t ==============

          #!!!! This avc is allowed in the current policy
          allow setroubleshootd_t proc_t:filesystem getattr;

          #============= system_dbusd_t ==============
          allow system_dbusd_t self:capability net_admin;
          allow system_dbusd_t setroubleshootd_t:process { noatsecure rlimitinh siginh };
          allow system_dbusd_t unconfined_service_t:process { noatsecure rlimitinh siginh };

    - name: Convert TE file into a policy moduel
      shell: checkmodule -M -m -o /tmp/qe-ssh-tunnel.mod /tmp/qe-ssh-tunnel.te

    - name: compile and generate policy package
      shell: semodule_package -o /tmp/qe-ssh-tunnel.pp -m /tmp/qe-ssh-tunnel.mod

    - name: Loaded qe-ssh-tunnel policy package
      shell: sudo semodule -B && sudo semodule -i /tmp/qe-ssh-tunnel.pp

    - name: list qe-ssh-tunnel policy module
      shell: sudo semodule -l | grep qe-ssh-tunnel
      register: res

    - debug: var=res.stdout
    when: major_platform_version == "8"

  - name: Set the SElinux context for id_rsa.pem
    shell: chcon -t user_home_t /tmp/id_rsa.pem
    when: major_platform_version == "8"

  - name: Start ssh tunnel service
    systemd:
      name: qe-ssh-tunnel
      enabled: yes
      daemon_reload: yes
      state: started

  - name: Check tunnel is running
    shell: ss -tlnup | grep 5080
    register: test_ssh_tunnel
    retries: 2
    delay: 50
    until: "test_ssh_tunnel.rc == 0"

  - debug: var=test_ssh_tunnel

  - set_fact:
      socks_proxy: "socks5h://localhost:5080"

  - name: Configure ssh yum
    blockinfile:
      path: /etc/yum.conf
      block: |
        proxy={{socks_proxy}}
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" scaleup-pre-hook-ssh-tunnel.yaml -vvv
