#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common gather command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

cat > gather_logs.yaml <<-EOF
- name: Gather logs and debug information and save them for debug purpose
  hosts: all
  vars:
    LOGS_DIR: /tmp/artifacts
    GATHER_CAPI_LOGS: "{{ lookup('env', 'GATHER_CAPI_LOGS') }}"
    CLUSTER_TYPE: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    CLUSTER_GATHER:
      - "{{ (lookup('env', 'SOSREPORT') == 'true') | ternary('--sosreport','', '') }}"
      - "{{ (lookup('env', 'MUST_GATHER') == 'true') | ternary('--must-gather','', '') }}"
      - "{{ (lookup('env', 'GATHER_ALL_CLUSTERS') == 'true') | ternary('--download-all','', '') }}"
  tasks:
    - name: Gather logs and debug information
      block:
      - name: Copy junit report files
        copy:
          remote_src: true
          src: /home/assisted/reports
          dest: "{{ LOGS_DIR }}"
      - name: Run sos report
        ansible.builtin.shell: |
          source /root/config.sh
          # Get sosreport including sar data
          sos report --batch --tmp-dir {{ LOGS_DIR }} --all-logs \
            -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,yum \
            -k podman.all -k podman.logs
      - name: Copy libvirt qemu log
        copy:
          remote_src: true
          src: /var/log/swtpm/libvirt/qemu/
          dest: "{{ LOGS_DIR }}/libvirt-qemu"
      - name: List swtpm-localca files to a file
        ansible.builtin.shell: |
          ls -ltr /var/lib/swtpm-localca/ >> {{ LOGS_DIR }}/libvirt-qemu/ls-swtpm-localca.txt
      - name: Equinix specific tasks
        block:
        - name: Fetch equinix metadata
          ansible.builtin.uri:
            url: "https://metadata.platformequinix.com/metadata"
            return_content: yes
          register: equinix_metadata
          until: equinix_metadata.status == 200
          retries: 5
          delay: 5
          no_log: true
        - name: Filter and dump equinix metadata
          ansible.builtin.copy:
            content: "{% set removed = equinix_metadata.json.pop('ssh_keys') %}{{ equinix_metadata.json | to_nice_json }}"
            dest: "{{ LOGS_DIR }}/equinix-metadata.json"
        when: "'packet' in CLUSTER_TYPE"
      - name: Check minikube kubeconfig file existence
        stat:
          path: /root/.kube/config
        register: kubeconfig
      - name: Extract assisted service logs
        make:
          chdir: /home/assisted
          target: download_service_logs
        environment:
          KUBECONFIG: "/root/.kube/config"
          LOGS_DEST: "{{ LOGS_DIR }}"
        when: kubeconfig.stat.exists
      - name: Extract capi logs
        make:
          chdir: /home/assisted
          target: download_capi_logs
        environment:
          KUBECONFIG: "/root/.kube/config"
          LOGS_DEST: "{{ LOGS_DIR }}"
        when: kubeconfig.stat.exists and GATHER_CAPI_LOGS == "true"
      - debug:
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
        find:
          paths: /home/assisted/build/kubeconfig
          patterns: "*kubeconfig*"
          recurse: true
        register: kubeconfig_files
      - name: Print kubeconfig file names
        debug:
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
    - name: Collect and download logs
      block:
      - name: Find all log files
        find:
          paths: /home/assisted/
          patterns: "*.log"
          recurse: true
        register: log_files
      - name: Print log file names
        debug:
          msg: "{{ item.path | basename }}"
        loop: "{{ log_files.files }}"
        loop_control:
          label: "{{ item.path }}"
      - name: Copy log files
        copy:
          remote_src: true
          src: "{{ item.path }}"
          dest: "{{ LOGS_DIR }}/{{ item.path | basename }}"
        loop: "{{ log_files.files }}"
        loop_control:
          label: "{{ item.path }}"
      - name: Download log files
        synchronize:
          src: "{{ LOGS_DIR }}/"
          dest: "{{ lookup('env', 'ARTIFACT_DIR') }}"
          mode: pull
EOF

ansible-playbook gather_logs.yaml -i ${SHARED_DIR}/inventory -vv
