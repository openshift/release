#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup prepare command ************"

# source common configuration, if missing, fallback on packet configuration
# shellcheck source=/dev/null
if ! source "${SHARED_DIR}/ci-machine-config.sh"; then
  source "${SHARED_DIR}/packet-conf.sh"
  export IP
  export SSH_KEY_FILE="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
fi

mkdir -p build/ansible
cd build/ansible

cat > packing-test-infra.yaml <<-EOF
- name: Prepare locally
  hosts: localhost
  collections:
    - community.general
  gather_facts: no
  vars:
    ansible_remote_tmp: ../tmp
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
  tasks:
    - name: Ensuring assisted-additional-config existence
      ansible.builtin.file:
        path: "{{ SHARED_DIR }}/assisted-additional-config"
        state: touch
    - name: Ensuring platform-conf.sh existence
      ansible.builtin.file:
        path: "{{ SHARED_DIR }}/platform-conf.sh"
        state: touch
    - name: Check if ansible inventory exists
      stat:
        path: "{{ SHARED_DIR }}/inventory"
      register: inventory
    - name: Create default ansible inventory
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/inventory"
        content: |
          [primary]
          primary-{{ lookup('env', 'IP') }} ansible_host={{ lookup('env', 'IP') }} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file={{ lookup('env', 'SSH_KEY_FILE') }} ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
      when: not inventory.stat.exists
    - name: Create ssh config file
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/ssh_config"
        content: |
          Host ci_machine
            User root
            HostName {{ lookup('env', 'IP') }}
            ConnectTimeout 5
            StrictHostKeyChecking no
            ServerAliveInterval 90
            LogLevel ERROR
            IdentityFile {{ lookup('env', 'SSH_KEY_FILE') }}
            ConnectionAttempts 10
    - name: Create ansible configuration
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/ansible.cfg"
        content: |
          [defaults]
          callback_whitelist = profile_tasks
          host_key_checking = False

          verbosity = 2
          stdout_callback = yaml
          bin_ansible_callbacks = True

          [ssh_connection]
          retries = 10
EOF

ansible-playbook packing-test-infra.yaml

# shellcheck disable=SC2034
export CI_CREDENTIALS_DIR=/var/run/assisted-installer-bot

echo "********** ${ASSISTED_CONFIG} ************* "

cat << EOF > config.sh.j2
export DATA_DIR={{ DATA_DIR }}
export REPO_DIR={{ REPO_DIR }}
export MINIKUBE_HOME={{ MINIKUBE_HOME }}
export INSTALLER_KUBECONFIG={{ REPO_DIR }}/build/kubeconfig
export PULL_SECRET=\$(cat /root/pull-secret)
export CI=true
export OPENSHIFT_CI=true
export REPO_NAME={{ REPO_NAME }}
export JOB_TYPE={{ JOB_TYPE }}
export PULL_NUMBER={{ PULL_NUMBER }}
export PULL_BASE_REF={{ PULL_BASE_REF }}
export RELEASE_IMAGE_LATEST={{ RELEASE_IMAGE_LATEST }}
export SERVICE={{ ASSISTED_SERVICE_IMAGE }}
export AGENT_DOCKER_IMAGE={{ ASSISTED_AGENT_IMAGE }}
export CONTROLLER_IMAGE={{ ASSISTED_CONTROLLER_IMAGE }}
export INSTALLER_IMAGE={{ ASSISTED_INSTALLER_IMAGE }}
export IMAGE_SERVICE={{ ASSISTED_IMAGE_SERVICE }}
export CHECK_CLUSTER_VERSION=True
export TEST_TEARDOWN=false
export TEST_FUNC=test_install
export ASSISTED_SERVICE_HOST={{ IP }}
export PUBLIC_CONTAINER_REGISTRIES="{{ CI_REGISTRIES | join(',') }}"
export OPENSHIFT_INSTALL_RELEASE_IMAGE={{ OPENSHIFT_INSTALL_RELEASE_IMAGE }}
export TF_APPLY_ATTEMPTS=3
export CPU_ARCHITECTURE="{{ CPU_ARCHITECTURE | default('x86_64') }}"
export DAY2_CPU_ARCHITECTURE="{{ DAY2_CPU_ARCHITECTURE | default('x86_64') }}"

{% if PROVIDER_IMAGE != ASSISTED_CONTROLLER_IMAGE %}
export PROVIDER_IMAGE={{ PROVIDER_IMAGE }}
{% endif %}

{% if HYPERSHIFT_IMAGE != ASSISTED_CONTROLLER_IMAGE %}
export HYPERSHIFT_IMAGE={{ HYPERSHIFT_IMAGE }}
{% endif %}

{% if JOB_TYPE == "presubmit" and REPO_NAME == "assisted-service" %}
export SERVICE_BRANCH={{ PULL_PULL_SHA }}
{% endif %}

source /root/platform-conf.sh
source /root/assisted-additional-config

{# Additional mechanism to inject assisted additional variables directly #}
{% if ASSISTED_CONFIG is defined %}
{# from a multistage step configuration. #}
{% set custom_param_list = ASSISTED_CONFIG.split('\n') %}
# Custom parameters
{% for item in custom_param_list %}
{% if item|trim|length %}
export {{ item }}
{% endif %}
{% endfor %}
{% endif %}
EOF

cat > run_test_playbook.yaml <<-"EOF"
- name: Prepare remote host
  hosts: primary
  vars:
    PLATFORM: "{{ lookup('env', 'PLATFORM') }}"
    PULL_PULL_SHA: "{{ lookup('env', 'PULL_PULL_SHA') | default('master', True) }}"
    JOB_TYPE: "{{ lookup('env', 'JOB_TYPE') }}"
    DATA_DIR: /home
    REPO_OWNER: "{{ lookup('env', 'REPO_OWNER') }}"
    REPO_NAME: "{{ lookup('env', 'REPO_NAME') }}"
    REPO_DIR: "{{ DATA_DIR }}/assisted"
    MINIKUBE_HOME: "{{ REPO_DIR }}/minikube_home"
    PULL_NUMBER: "{{ lookup('env', 'PULL_NUMBER') }}"
    PULL_BASE_REF: "{{ lookup('env', 'PULL_BASE_REF') }}"
    CI_CREDENTIALS_DIR: "{{ lookup('env', 'CI_CREDENTIALS_DIR') }}"
    CLUSTER_PROFILE_DIR: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}"
    IP: "{{ lookup('env', 'IP') }}"
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
    ASSISTED_SERVICE_IMAGE: "{{ lookup('env', 'ASSISTED_SERVICE_IMAGE') }}"
    ASSISTED_AGENT_IMAGE: "{{ lookup('env', 'ASSISTED_AGENT_IMAGE') }}"
    ASSISTED_CONTROLLER_IMAGE: "{{ lookup('env', 'ASSISTED_CONTROLLER_IMAGE') }}"
    ASSISTED_INSTALLER_IMAGE: "{{ lookup('env', 'ASSISTED_INSTALLER_IMAGE') }}"
    ASSISTED_IMAGE_SERVICE: "{{ lookup('env', 'ASSISTED_IMAGE_SERVICE') }}"
    RELEASE_IMAGE_LATEST: "{{ lookup('env', 'RELEASE_IMAGE_LATEST') }}"
    PROVIDER_IMAGE: "{{ lookup('env', 'PROVIDER_IMAGE') }}"
    HYPERSHIFT_IMAGE: "{{ lookup('env', 'HYPERSHIFT_IMAGE') }}"
    POST_INSTALL_COMMANDS: "{{ lookup('env', 'POST_INSTALL_COMMANDS') }}"
    ASSISTED_CONFIG: "{{ lookup('env', 'ASSISTED_CONFIG') }}"
    ASSISTED_TEST_INFRA_IMAGE: "{{ lookup('env', 'ASSISTED_TEST_INFRA_IMAGE')}}"
    CLUSTERTYPE: "{{ lookup('env', 'CLUSTERTYPE')}}"
    OPENSHIFT_INSTALL_RELEASE_IMAGE: "{{ lookup('env', 'OPENSHIFT_INSTALL_RELEASE_IMAGE')}}"
    CLUSTER_PROFILE_PULL_SECRET: "{{ lookup('file', '{{ CLUSTER_PROFILE_DIR }}/pull-secret') }}"
    BREW_REGISTRY_REDHAT_IO_PULL_SECRET: "{{ lookup('file', '/var/run/vault/brew-registry-redhat-io-pull-secret/pull-secret') }}"
  pre_tasks:
    - name: wait for ssh
      ansible.builtin.wait_for_connection:
        sleep: 30
        delay: 30
  tasks:
    # Some Packet images have a file /usr/config left from the provisioning phase.
    # The problem is that sos expects it to be a directory. Since we don't care
    # about the Packet provisioner, remove the file if it's present.
    - name: Delete /usr/config file
      ansible.builtin.file:
        path: /usr/config
        state: absent
    - name: Update pull secrets with brew.registry.redhat.io auth
      ansible.builtin.set_fact:
        pull_secret: "{{ CLUSTER_PROFILE_PULL_SECRET | combine(BREW_REGISTRY_REDHAT_IO_PULL_SECRET, recursive=true) }}"
      no_log: true
    - name: Setup pull-secret on remote
      become: true
      ansible.builtin.copy:
        content: "{{ pull_secret | to_nice_json }}"
        dest: /root/pull-secret
      no_log: true
    - name: Copy vsphere credentials file
      become: true
      ansible.builtin.copy:
        src: "{{ SHARED_DIR }}/platform-conf.sh"
        dest: /root/platform-conf.sh
    - name: Copy assisted-additional-config file
      become: true
      ansible.builtin.copy:
        src: "{{ SHARED_DIR }}/assisted-additional-config"
        dest: /root/assisted-additional-config
    - name: Install packages
      dnf:
        name:
        - git
        - sysstat
        - sos
        - jq
        - make
        - podman
        - rsync
        state: present
    - name: Restart service sysstat
      ansible.builtin.service:
        name: sysstat
        state: restarted
    - name: Create artifacts directory if it does not exist
      ansible.builtin.file:
        path: /tmp/artifacts
        state: directory
    - name: Create repo directory if it does not exist
      ansible.builtin.file:
        path: "{{ REPO_DIR }}"
        state: directory
    - name: Create minikube directory if it does not exist
      ansible.builtin.file:
        path: "{{ MINIKUBE_HOME }}"
        state: directory
    - name: Initialize CI_REGISTRIES fact
      set_fact:
        CI_REGISTRIES: []
    - name: Get repositories from images
      set_fact:
        CI_REGISTRIES: "{{ CI_REGISTRIES + [ item.split('/') | first ] }}"
      loop:
      - quay.io
      - "{{ ASSISTED_AGENT_IMAGE }}"
      - "{{ ASSISTED_CONTROLLER_IMAGE }}"
      - "{{ ASSISTED_INSTALLER_IMAGE }}"
      - "{{ ASSISTED_IMAGE_SERVICE }}"
      - "{{ RELEASE_IMAGE_LATEST }}"
    - debug:
        msg: "CI_REGISTRIES = {{ CI_REGISTRIES }}"
    - name: Create {{ REPO_DIR }} directory if it does not exist
      ansible.builtin.file:
        path: "{{ REPO_DIR }}"
        state: directory
    - debug:
        var: CLUSTERTYPE
    - name: Setup working directory for large machines
      ansible.builtin.shell: |
        # Get disk where / is mounted
        ROOT_DISK=$(lsblk -o pkname --noheadings --path | grep -E "^\S+" | sort | uniq)

        # Use the largest disk available for assisted
        DATA_DISK=$(lsblk -o name --noheadings --sort size --path | grep -v "${ROOT_DISK}" | tail -n1)
        if [[ -z "$DATA_DISK" ]]; then
          exit 0
        fi

        mkfs.xfs -f "${DATA_DISK}"
        mount "${DATA_DISK}" {{ REPO_DIR }}
      when: '"large" in CLUSTERTYPE'
    - name: Create {{ MINIKUBE_HOME }} directory if it does not exist
      ansible.builtin.file:
        path: "{{ MINIKUBE_HOME }}"
        state: directory
    - name: Build config.sh file
      template:
        src: ./config.sh.j2
        dest: /root/config.sh
    - name: Print config file content
      debug:
        msg: "{{ lookup('template', './config.sh.j2').split('\n') }}"
    - name: Retrieve assisted-test-infra sources
      block:
        - name: Pull {{ ASSISTED_TEST_INFRA_IMAGE }}
          ansible.builtin.shell: |
            podman pull "{{ ASSISTED_TEST_INFRA_IMAGE }}"
        - name: Get working directory in {{ ASSISTED_TEST_INFRA_IMAGE }}
          ansible.builtin.shell: |
            podman inspect --format "{% raw %}{{ .Config.WorkingDir }}{% endraw %}" "{{ ASSISTED_TEST_INFRA_IMAGE }}"
          register: assisted_test_infra_src_path
        - name: Copy assisted-test-infra sources from {{ ASSISTED_TEST_INFRA_IMAGE }}:{{ assisted_test_infra_src_path.stdout }} to {{ REPO_DIR }}
          ansible.builtin.shell: |
            podman create --name src "{{ ASSISTED_TEST_INFRA_IMAGE }}"
            podman cp "src:{{ assisted_test_infra_src_path.stdout }}/." "{{ REPO_DIR }}"
            podman rm -f src
    - name: Create post install script
      ansible.builtin.copy:
        dest: /root/assisted-post-install.sh
        content: |
          {{ POST_INSTALL_COMMANDS }}
          echo "Finish running post installation script"
EOF

export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
ansible-playbook run_test_playbook.yaml -i "${SHARED_DIR}/inventory"
