#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup prepare command ************"

mkdir -p build/ansible
cd build/ansible

cat > packing-test-infra.yaml <<-EOF
- name: Packing assisted-test-infra
  hosts: localhost
  collections:
    - community.general
  gather_facts: no
  vars:
    ansible_remote_tmp: ../tmp
  tasks:
    - name: Compress
      community.general.archive:
        path: ../../
        exclude_path:
          - ../../build
        dest: assisted-test-infra.tgz
EOF

ansible-playbook packing-test-infra.yaml

# Get packet | vsphere configuration
# shellcheck source=/dev/null
set +e
source "${SHARED_DIR}/packet-conf.sh"
source "${SHARED_DIR}/ci-machine-config.sh"
set -e

# shellcheck disable=SC2034
export CI_CREDENTIALS_DIR=/var/run/assisted-installer-bot
touch ${SHARED_DIR}/assisted-additional-config

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

cat << EOF > inventory
[all]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${SSH_KEY_FILE} ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
EOF

cat << EOF > config.sh.j2
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
export MAKEFILE_TARGET='setup run test_parallel'
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

{% if PLATFORM == "vsphere" %}
export PLATFORM=vsphere
export VIP_DHCP_ALLOCATION=false
export VSPHERE_PARENT_FOLDER=assisted-test-infra-ci
export VSPHERE_FOLDER="build-{{ lookup('env', 'BUILD_ID') }}"
export TEST_TEARDOWN=true
source /root/vsphere_test_infra.sh
{% endif %}

{# Additional mechanism to inject assisted additional variables directly #}
{% if ASSISTED_CONFIG is defined %}
{# from a multistage step configuration. #}
{% set custom_param_list = ASSISTED_CONFIG.split('\n') %}
# Custom parameters
{% for item in custom_param_list %}
export {{ item }}
{% endfor %}
{% endif %}
EOF

cat > run_test_playbook.yaml <<-EOF
- name: Prepare remote host
  hosts: all
  vars:
    PLATFORM: "{{ lookup('env', 'PLATFORM') }}"
    PULL_PULL_SHA: "{{ lookup('env', 'PULL_PULL_SHA') | default('master', True) }}"
    JOB_TYPE: "{{ lookup('env', 'JOB_TYPE') }}"
    REPO_OWNER: "{{ lookup('env', 'REPO_OWNER') }}"
    REPO_NAME: "{{ lookup('env', 'REPO_NAME') }}"
    REPO_DIR: /home/assisted
    MINIKUBE_HOME: "{{ REPO_DIR }}/minikube_home"
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
    - name: Copy tar to remote
      become: true
      ansible.builtin.copy:
        src: assisted-test-infra.tgz
        dest: /root/assisted.tar.gz
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
        src: "{{ SHARED_DIR }}/vsphere_test_infra.sh"
        dest: /root/vsphere_test_infra.sh
    - name: Install packages
      dnf:
        name:
        - git
        - sysstat
        - sos
        - jq
        - make
        state: present
    - name: Restart service sysstat
      ansible.builtin.service:
        name: sysstat
        state: restarted
    - name: Create artifacts directory if it does not exist
      ansible.builtin.file:
        path: /tmp/artifacts
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
    # NVMe makes it faster
    - name: Save state of VNVME device to the nvme register
      stat:
        path: /dev/nvme0n1
      register: nvme
    - name: Build config.sh file
      template:
        src: ./config.sh.j2
        dest: /root/config.sh
    - name: Print config file content
      debug:
        msg: "{{ lookup('template', './config.sh.j2') }}"
    - name: Use nvme device if exists
      ansible.builtin.shell: |
        mkfs.xfs -f /dev/nvme0n1
        mount /dev/nvme0n1 {{ REPO_DIR }}
      when: nvme.stat.exists
    - name: Extract test-infra repo archive
      ansible.builtin.unarchive:
        src: /root/assisted.tar.gz
        dest: "{{ REPO_DIR }}"
        remote_src: yes
        owner: root
        group: root
        mode: 0755
EOF

ansible-playbook run_test_playbook.yaml -i inventory
