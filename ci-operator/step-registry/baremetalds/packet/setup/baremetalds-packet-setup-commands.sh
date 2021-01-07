#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet setup command ************"

# Run Ansible playbook
cd
cat > packet-setup.yaml <<-EOF
- name: setup Packet host
  hosts: localhost
  collections:
   - community.general
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    - slackhook_path: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}"
  vars_files:
    - "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}/.packet-kni-vars"

  tasks:

  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: cluster_type != "packet"

  - name: create Packet host with error handling
    block:
    - name: create Packet host {{ packet_hostname }}
      packet_device:
        auth_token: "{{ packet_auth_token }}"
        project_id: "{{ packet_project_id }}"
        hostnames: "{{ packet_hostname }}"
        operating_system: centos_8
        plan: m2.xlarge.x86
        facility: any
        wait_for_public_IPv: 4
        state: active
        tags: "{{ 'PR:', lookup('env', 'PULL_NUMBER'), 'Job name:', lookup('env', 'JOB_NAME'), 'Job id:', lookup('env', 'PROW_JOB_ID') }}"
      register: hosts
      no_log: true
    - name: wait for ssh
      wait_for:
        delay: 5
        host: "{{ hosts.devices[0].public_ipv4 }}"
        port: 22
        state: started
        timeout: 900
    rescue:
    - name: Send notification message via Slack in case of failure
      slack:
        token: "{{ 'T027F3GAJ/B011TAG710V/' + lookup('file', slackhook_path + '/.slackhook') }}"
        msg: "Packet setup failed. Error msg: {{ ansible_failed_result.msg }}"
        username: "{{ packet_hostname }}"
        color: warning
        icon_emoji: ":failed:"
    - name: fail the play
      fail:
        msg: "ERROR: Packet setup failed."

  - name: save Packet IP
    local_action: copy content="{{ hosts.devices[0].public_ipv4 }}" dest="{{ lookup('env', 'SHARED_DIR') }}/server-ip"

  - name: write fix uid file
    copy:
      content: |
        # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
        # to be able to SSH.
        if ! whoami &> /dev/null; then
            if [ -x "\$(command -v nss_wrapper.pl)" ]; then
                grep -v -e ^default -e ^\$(id -u) /etc/passwd > "/tmp/passwd"
                echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> "/tmp/passwd"
                export LD_PRELOAD=libnss_wrapper.so
                export NSS_WRAPPER_PASSWD=/tmp/passwd
                export NSS_WRAPPER_GROUP=/etc/group
            elif [[ -w /etc/passwd ]]; then
                echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> "/etc/passwd"
            else
                echo "No nss wrapper, /etc/passwd is not writeable, and user matching this uid is not found."
                exit 1
            fi
        fi
      dest: "${SHARED_DIR}/fix-uid.sh"

  - name: write Packet common configuration file
    copy:
      content: |
        source "\${SHARED_DIR}/fix-uid.sh"

        # Initial check
        if [ "\${CLUSTER_TYPE}" != "packet" ]; then
            echo >&2 "Unsupported cluster type '\${CLUSTER_TYPE}'"
            exit 1
        fi

        IP=\$(cat "\${SHARED_DIR}/server-ip")
        SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "\${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

        # Checkout packet server
        for x in \$(seq 10) ; do
            test "\${x}" -eq 10 && exit 1
            ssh "\${SSHOPTS[@]}" "root@\${IP}" hostname && break
            sleep 10
        done
      dest: "${SHARED_DIR}/packet-conf.sh"
EOF

ansible-playbook packet-setup.yaml -e "packet_hostname=ipi-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}"
