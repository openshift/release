#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup prepare command ************"

# Get packet | vsphere configuration
# shellcheck source=/dev/null
if source "${SHARED_DIR}/packet-conf.sh"; then
  export IP
  export SSH_KEY_FILE="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
else
  source "${SHARED_DIR}/ci-machine-config.sh"
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
    - name: Create ansible inventory
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/inventory"
        content: |
          [all]
          {{ lookup('env', 'IP') }} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file={{ lookup('env', 'SSH_KEY_FILE') }} ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
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
EOF

ansible-playbook packing-test-infra.yaml

# shellcheck disable=SC2034
export CI_CREDENTIALS_DIR=/var/run/assisted-installer-bot

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

echo "********** ${ASSISTED_CONFIG} ************* "

cat << EOF > config.sh.j2
export DATA_DIR={{ DATA_DIR }}
export REPO_DIR={{ REPO_DIR }}
export MINIKUBE_HOME={{ MINIKUBE_HOME }}
export INSTALLER_KUBECONFIG={{ REPO_DIR }}/build/kubeconfig
export PULL_SECRET=\$(cat /root/pull-secret)
export CI=true
export OPENSHIFT_CI=true
export REPO_NAME={{ lookup('env', 'REPO_NAME') }}
export JOB_TYPE={{ lookup('env', 'JOB_TYPE') }}
export PULL_NUMBER={{ lookup('env', 'PULL_NUMBER') }}
export RELEASE_IMAGE_LATEST={{ RELEASE_IMAGE_LATEST }}
export SERVICE={{ lookup('env', 'ASSISTED_SERVICE_IMAGE') }}
export AGENT_DOCKER_IMAGE={{ ASSISTED_AGENT_IMAGE }}
export CONTROLLER_IMAGE={{ ASSISTED_CONTROLLER_IMAGE }}
export INSTALLER_IMAGE={{ ASSISTED_INSTALLER_IMAGE }}
export CHECK_CLUSTER_VERSION=True
export TEST_TEARDOWN=false
export TEST_FUNC=test_install
export ASSISTED_SERVICE_HOST={{ IP }}
export PUBLIC_CONTAINER_REGISTRIES="{{ CI_REGISTRIES | join(',') }}"

{% if ENVIRONMENT == "production" %}
# Testing against the production AI parameters
export PULL_SECRET=\$(cat /root/prod/pull-secret)
export OFFLINE_TOKEN=\$(cat /root/prod/offline-token)
export REMOTE_SERVICE_URL=https://api.openshift.com
export NO_MINIKUBE=true
export MAKEFILE_TARGET='setup test_parallel'
{% endif %}

{% if PROVIDER_IMAGE != ASSISTED_CONTROLLER_IMAGE %}
export PROVIDER_IMAGE={{ PROVIDER_IMAGE }}
{% endif %}

{% if PROVIDER_IMAGE != ASSISTED_CONTROLLER_IMAGE %}
export HYPERSHIFT_IMAGE={{ HYPERSHIFT_IMAGE }}
{% endif %}

{% if JOB_TYPE == "presubmit" and REPO_NAME == "assisted-service" %}
export SERVICE_BRANCH={{ PULL_PULL_SHA }}
{% endif %}

{% if REPO_NAME != "assisted-service" %}
export OPENSHIFT_INSTALL_RELEASE_IMAGE={{ RELEASE_IMAGE_LATEST }}
{% endif %}

source /root/platform-conf.sh

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
  hosts: all
  vars:
    PLATFORM: "{{ lookup('env', 'PLATFORM') }}"
    PULL_PULL_SHA: "{{ lookup('env', 'PULL_PULL_SHA') | default('master', True) }}"
    JOB_TYPE: "{{ lookup('env', 'JOB_TYPE') }}"
    DATA_DIR: /home
    REPO_OWNER: "{{ lookup('env', 'REPO_OWNER') }}"
    REPO_NAME: "{{ lookup('env', 'REPO_NAME') }}"
    REPO_DIR: "{{ DATA_DIR }}/assisted"
    MINIKUBE_HOME: "{{ DATA_DIR }}/minikube_home"
    CI_CREDENTIALS_DIR: "{{ lookup('env', 'CI_CREDENTIALS_DIR') }}"
    CLUSTER_PROFILE_DIR: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}"
    IP: "{{ lookup('env', 'IP') }}"
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
    ASSISTED_AGENT_IMAGE: "{{ lookup('env', 'ASSISTED_AGENT_IMAGE') }}"
    ASSISTED_CONTROLLER_IMAGE: "{{ lookup('env', 'ASSISTED_CONTROLLER_IMAGE') }}"
    ASSISTED_INSTALLER_IMAGE: "{{ lookup('env', 'ASSISTED_INSTALLER_IMAGE') }}"
    RELEASE_IMAGE_LATEST: "{{ lookup('env', 'RELEASE_IMAGE_LATEST') }}"
    PROVIDER_IMAGE: "{{ lookup('env', 'PROVIDER_IMAGE') }}"
    HYPERSHIFT_IMAGE: "{{ lookup('env', 'HYPERSHIFT_IMAGE') }}"
    ENVIRONMENT: "{{ lookup('env', 'ENVIRONMENT') }}"
    POST_INSTALL_COMMANDS: "{{ lookup('env', 'POST_INSTALL_COMMANDS') }}"
    ASSISTED_CONFIG: "{{ lookup('env', 'ASSISTED_CONFIG') }}"
    ASSISTED_TEST_INFRA_IMAGE: "{{ lookup('env', 'ASSISTED_TEST_INFRA_IMAGE')}}"
    CLUSTER_TYPE: "{{ lookup('env', 'CLUSTER_TYPE')}}"
  tasks:
    - name: Fail on unsupported environment
      fail:
        msg: "Unsupported environment {{ ENVIRONMENT }}"
      when: ENVIRONMENT != "local" and ENVIRONMENT != "production"
    # Some Packet images have a file /usr/config left from the provisioning phase.
    # The problem is that sos expects it to be a directory. Since we don't care
    # about the Packet provisioner, remove the file if it's present.
    - name: Delete /usr/config file
      ansible.builtin.file:
        path: /usr/config
        state: absent
    - name: Copy pull-secret to remote
      become: true
      ansible.builtin.copy:
        src: "{{ CLUSTER_PROFILE_DIR }}/pull-secret"
        dest: /root/pull-secret
    - name: Create prod directory
      ansible.builtin.file:
        path: /root/prod
        state: directory
    - name: Copy prod offline-token to remote
      become: true
      ansible.builtin.copy:
        src: "{{ CI_CREDENTIALS_DIR }}/offline-token"
        dest: /root/prod/offline-token
    - name: Copy prod pull-secret to remote
      become: true
      ansible.builtin.copy:
        src: "{{ CI_CREDENTIALS_DIR }}/prod-pull-secret"
        dest: /root/prod/pull-secret
    - name: Copy vsphere credentials file
      become: true
      ansible.builtin.copy:
        src: "{{ SHARED_DIR }}/platform-conf.sh"
        dest: /root/platform-conf.sh
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
      - "{{ ASSISTED_AGENT_IMAGE }}"
      - "{{ ASSISTED_CONTROLLER_IMAGE }}"
      - "{{ RELEASE_IMAGE_LATEST }}"
      - "{{ ASSISTED_INSTALLER_IMAGE }}"
      - quay.io
    - debug:
        msg: "CI_REGISTRIES = {{ CI_REGISTRIES }}"
    - name: Create {{ REPO_DIR }} directory if it does not exist
      ansible.builtin.file:
        path: "{{ REPO_DIR }}"
        state: directory
    - debug:
        var: CLUSTER_TYPE
    - name: Customize equinix machine
      block:
      - name: Fetch equinix metadata
        ansible.builtin.uri:
          url: "https://metadata.platformequinix.com/metadata"
          return_content: yes
        register: equinix_metadata
        until: equinix_metadata.status == 200
        retries: 5
        delay: 5
      - name: Setup working directory for machine type m3.large.x86
        ansible.builtin.shell: |
          mkfs.xfs -f /dev/nvme0n1
          mount /dev/nvme0n1 {{ REPO_DIR }}
        when: "equinix_metadata.json.plan == 'm3.large.x86'"
      - name: Setup working directory and swap for machine type c3.medium.x86
        ansible.builtin.shell: |
          # c3.medium.x86 has 64GB of RAM which is not enough for most of assisted jobs.
          # We need to mount extra swap space in order allow memory overcommit with libvirt/KVM.
          # The machine is supposed to have 2x240G disks (one is used for the system) and
          # 2x480GB disks (sometimes missing).

          # Get disk where / is mounted
          ROOT_DISK=$(lsblk -o pkname --noheadings --path | grep -E "^\S+" | sort | uniq)

          # Setup the smallest disk available (240GB) as swap
          SWAP_DISK=$(lsblk -o name --noheadings --sort size --path | grep -v "${ROOT_DISK}" | head -n1)
          mkswap "${SWAP_DISK}"
          swapon "${SWAP_DISK}"
        when: "equinix_metadata.json.plan == 'c3.medium.x86'"
      when: '"packet" in CLUSTER_TYPE'
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

ansible-playbook run_test_playbook.yaml -i "${SHARED_DIR}/inventory"
