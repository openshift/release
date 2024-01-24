#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common gather command ************"

cat > gather_logs.yaml <<-EOF
- name: Gather logs and debug information and save them for debug purpose
  hosts: all
  vars:
    LOGS_DIR: /tmp/artifacts
    GATHER_CAPI_LOGS: "{{ lookup('env', 'GATHER_CAPI_LOGS') }}"
    CLUSTER_GATHER:
      - "{{ (lookup('env', 'SOSREPORT') == 'true') | ternary('--sosreport','', '') }}"
      - "{{ (lookup('env', 'MUST_GATHER') == 'true') | ternary('--must-gather','', '') }}"
      - "{{ (lookup('env', 'GATHER_ALL_CLUSTERS') == 'true') | ternary('--download-all','', '') }}"
  tasks:
    - name: Gather logs and debug information from all hosts
      block:
      - name: Ensure LOGS_DIR exists
        ansible.builtin.file:
          path: "{{ LOGS_DIR }}"
          state: directory
          mode: '0755'

      # setsid is there to workaround an issue with virsh hanging when running in background
      # https://serverfault.com/questions/1105733/virsh-command-hangs-when-script-runs-in-the-background
      - name: Gather sosreport from all hosts
        ansible.builtin.command: >-
          setsid sos report --batch --tmp-dir "{{ LOGS_DIR }}" --all-logs
            -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,dnf
            -k podman.all -k podman.logs
      ignore_errors: true

    - name: Gather logs and debug information from primary host
      block:
      - name: Copy terraform log
        ansible.builtin.copy:
          remote_src: true
          src: /home/assisted/build/terraform/
          dest: "{{ LOGS_DIR }}"

      - name: Copy junit report files
        ansible.builtin.copy:
          remote_src: true
          src: /home/assisted/reports
          dest: "{{ LOGS_DIR }}"

      - name: Check minikube kubeconfig file existence
        ansible.builtin.stat:
          path: /root/.kube/config
        register: kubeconfig

      - name: Extract assisted service logs
        ansible.builtin.shell: |
          source /root/config.sh
          make download_service_logs
        environment:
          KUBECONFIG: "/root/.kube/config"
          LOGS_DEST: "{{ LOGS_DIR }}"
        args:
          chdir: /home/assisted
        when: kubeconfig.stat.exists

      - name: Extract capi logs
        ansible.builtin.shell: |
          source /root/config.sh
          make download_capi_logs
        environment:
          KUBECONFIG: "/root/.kube/config"
          LOGS_DEST: "{{ LOGS_DIR }}"
        args:
          chdir: /home/assisted
        when: kubeconfig.stat.exists and GATHER_CAPI_LOGS == "true"

      - name: Print CLUSTER_GATHER value
        ansible.builtin.debug:
          msg: "CLUSTER_GATHER = {{ CLUSTER_GATHER }}"

      - name: Download cluster logs
        ansible.builtin.shell: |
          source /root/config.sh
          make download_cluster_logs
        environment:
          ADDITIONAL_PARAMS: "{{ CLUSTER_GATHER | join(' ') }}"
          KUBECONFIG: "/root/.kube/config"
          LOGS_DEST: "{{ LOGS_DIR }}"
        args:
          chdir: /home/assisted

      - name: Find kubeconfig files
        ansible.builtin.find:
          paths: /home/assisted/build/kubeconfig
          patterns: "*kubeconfig*"
          recurse: true
        register: kubeconfig_files

      - name: Print kubeconfig file names
        ansible.builtin.debug:
          msg: "{{ item.path | basename }}"
        loop: "{{ kubeconfig_files.files }}"
        loop_control:
          label: "{{ item.path }}"

      - name: Download service logs
        ansible.builtin.shell: |
          make download_service_logs
        environment:
          KUBECONFIG: "{{ item.path }}"
          LOGS_DEST: "{{ LOGS_DIR }}/new_cluster_{{ item.path | basename }}"
        args:
          chdir: /home/assisted
        loop: "{{ kubeconfig_files.files }}"
        loop_control:
          label: "{{ item.path }}"
      ignore_errors: yes
      when: "'primary' in group_names"

    - name: Collect and download logs from primary host
      block:
      - name: Find all log files
        ansible.builtin.find:
          paths: /home/assisted/
          patterns: "*.log"
          recurse: true
        register: log_files

      - name: Print log file names
        ansible.builtin.debug:
          msg: "{{ item.path | basename }}"
        loop: "{{ log_files.files }}"
        loop_control:
          label: "{{ item.path }}"

      - name: Copy log files
        ansible.builtin.copy:
          remote_src: true
          src: "{{ item.path }}"
          dest: "{{ LOGS_DIR }}/{{ item.path | basename }}"
        loop: "{{ log_files.files }}"
        loop_control:
          label: "{{ item.path }}"
      ignore_errors: yes
      when: "'primary' in group_names"

    - name: Collect and download logs from all hosts
      block:
      - name: Download log files
        ansible.builtin.synchronize:
          src: "{{ LOGS_DIR }}/"
          dest: "{{ lookup('env', 'ARTIFACT_DIR') }}"
          mode: pull
      ignore_errors: yes
EOF

export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
ansible-playbook gather_logs.yaml -i "${SHARED_DIR}/inventory"
