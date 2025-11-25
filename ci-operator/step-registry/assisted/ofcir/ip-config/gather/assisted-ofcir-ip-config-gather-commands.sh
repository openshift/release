#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config-gather command ************"

export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"

if [[ ! -f "$ANSIBLE_CONFIG" ]]; then
    echo "Ansible config not found at: ${ANSIBLE_CONFIG}" >&2
    exit 1
fi
export ANSIBLE_CONFIG

ANSIBLE_INVENTORY="${SHARED_DIR}/inventory"
if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
    echo "Ansible inventory not found at: ${ANSIBLE_INVENTORY}" >&2
    exit 1
fi
export ANSIBLE_INVENTORY

cat > ip-config.yaml <<'PLAYBOOK'
- name: Gather logs from the lifecycle-agent ip-config flow
  hosts: primary
  gather_facts: true
  vars:
    controller_logs_dir: "{{ lookup('env', 'ARTIFACT_DIR') }}"
    primary_logs_dir: "/home/assisted/logs"
    vm_ssh_user: core
    shared_dir: "{{ lookup('env', 'SHARED_DIR') | default('', true) }}"
  tasks:
    - name: Find all kubeconfig files
      ansible.builtin.find:
        paths: "{{ ansible_env.KUBECONFIG }}"
        file_type: file
      register: kubeconfigs
      changed_when: false

    - name: Fail if no kubeconfig files are found
      ansible.builtin.fail:
        msg: "There should be exactly one kubeconfig file in {{ ansible_env.KUBECONFIG }}, but found {{ kubeconfigs.matched }}"
      when: kubeconfigs.matched != 1

    - name: Set kubeconfig file
      ansible.builtin.set_fact:
        kubeconfig_file: "{{ kubeconfigs.files[0].path }}"

    - name: Ensure controller logs dir exists
      ansible.builtin.file:
        path: "{{ controller_logs_dir }}"
        state: directory
        mode: '0755'

    - name: Ensure primary logs dir exists
      ansible.builtin.file:
        path: "{{ primary_logs_dir }}"
        state: directory
        mode: '0755'

    - name: Best-effort logs collection
      ignore_errors: yes
      block:
        - name: Fetch current IPConfig CR
          ansible.builtin.command:
            cmd: "oc --kubeconfig {{ kubeconfig_file }} get ipconfig ipconfig -o json"
          register: ipc_get
          changed_when: false

        - name: Parse IPConfig JSON
          ansible.builtin.set_fact:
            ipc: "{{ ipc_get.stdout | from_json }}"

        - name: Copy IPConfig JSON to primary logs dir
          ansible.builtin.copy:
            content: "{{ ipc_get.stdout }}"
            dest: "{{ primary_logs_dir }}/ipconfig.json"

        - name: get lca pod name
          ansible.builtin.command:
            cmd: "oc --kubeconfig {{ kubeconfig_file }} get pods -n openshift-lifecycle-agent -o jsonpath='{.items[0].metadata.name}'"
          register: lca_pod_name
          changed_when: false

        - name: Get lca logs
          ansible.builtin.command:
            cmd: "oc --kubeconfig {{ kubeconfig_file }} logs -n openshift-lifecycle-agent {{ lca_pod_name.stdout }}"
          register: lca_logs
          changed_when: false

        - name: Write lca logs to primary logs dir
          ansible.builtin.copy:
            content: "{{ lca_logs.stdout }}"
            dest: "{{ primary_logs_dir }}/lifecycle-agent.log"

        - name: Load stored IPs from shared dir on controller
          ansible.builtin.set_fact:
            ipc_ipv4_old: "{{ (shared_dir | length > 0) | ternary(lookup('file', shared_dir + '/ipconfig_ipv4_old', errors='ignore'), '') | default('', true) | trim }}"
            ipc_ipv4_new: "{{ (shared_dir | length > 0) | ternary(lookup('file', shared_dir + '/ipconfig_ipv4_new', errors='ignore'), '') | default('', true) | trim }}"
            ipc_ipv6_old: "{{ (shared_dir | length > 0) | ternary(lookup('file', shared_dir + '/ipconfig_ipv6_old', errors='ignore'), '') | default('', true) | trim }}"
            ipc_ipv6_new: "{{ (shared_dir | length > 0) | ternary(lookup('file', shared_dir + '/ipconfig_ipv6_new', errors='ignore'), '') | default('', true) | trim }}"

        - name: Build list of candidate node IPs
          ansible.builtin.set_fact:
            candidate_node_ips: >-
              [ "{{ ipc_ipv4_old }}", "{{ ipc_ipv4_new }}", "{{ ipc_ipv6_old }}", "{{ ipc_ipv6_new }}" ]

        - name: Ensure lca-cli log directory exists
          ansible.builtin.file:
            path: "{{ primary_logs_dir }}/lca-cli"
            state: directory
            mode: '0755'

        - name: Wait until one candidate IP is reachable on SSH
          ansible.builtin.wait_for:
            host: "{{ item }}"
            port: 22
            timeout: 3
          loop: "{{ candidate_node_ips | reject('equalto', '') | list }}"
          register: wait_results
          until: wait_results is succeeded
          retries: "{{ (candidate_node_ips | reject('equalto', '') | list) | length }}"
          delay: 2
          changed_when: false

        - name: Set reachable node IP fact
          ansible.builtin.set_fact:
            reachable_node_ip: >-
              {{ wait_results.results
                 | selectattr('failed', 'defined')
                 | selectattr('failed', 'equalto', false)
                 | map(attribute='item')
                 | first }}

        - name: Get node workspace
          ansible.builtin.shell: |
            ssh -o StrictHostKeyChecking=no {{ vm_ssh_user }}@{{ reachable_node_ip }} \
              'sudo tar -C /var/lib/lca --exclude=workspace/kubeconfig-crypto -cf - workspace' | \
              tar -C {{ primary_logs_dir }} -xf -
          args:
            executable: /bin/bash
          changed_when: false

        - name: Get lca-cli ip-config prepare logs
          ansible.builtin.command:
            cmd: "ssh -o StrictHostKeyChecking=no {{ vm_ssh_user }}@{{ reachable_node_ip }} sudo journalctl -u lca-ipconfig-prepare --no-pager"
          register: lca_ipconfig_prepare_logs
          changed_when: false

        - name: Get lca-cli ip-config run logs
          ansible.builtin.command:
            cmd: "ssh -o StrictHostKeyChecking=no {{ vm_ssh_user }}@{{ reachable_node_ip }} sudo journalctl -u lca-ipconfig-run --no-pager"
          register: lca_ipconfig_run_logs
          changed_when: false

        - name: Write lca-cli ip-config prepare logs to primary logs dir
          ansible.builtin.copy:
            content: "{{ lca_ipconfig_prepare_logs.stdout }}"
            dest: "{{ primary_logs_dir }}/lca-cli/lca-ipconfig-prepare.log"

        - name: Write lca-cli ip-config run logs to primary logs dir
          ansible.builtin.copy:
            content: "{{ lca_ipconfig_run_logs.stdout }}"
            dest: "{{ primary_logs_dir }}/lca-cli/lca-ipconfig-run.log"

        - name: Sync primary logs dir contents to controller logs dir
          ansible.builtin.synchronize:
            src: "{{ primary_logs_dir }}/"
            dest: "{{ controller_logs_dir }}/"
            mode: pull
PLAYBOOK

ansible-playbook -i "${ANSIBLE_INVENTORY}" ip-config.yaml