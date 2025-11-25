#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config-test command ************"

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
- name: Perform lifecycle-agent IP Config flow
  hosts: primary
  gather_facts: true
  vars:
    change_ipv4: "{{ lookup('env', 'LCA_IPC_IPV4') | default('', true) }}"
    change_ipv6: "{{ lookup('env', 'LCA_IPC_IPV6') | default('', true) }}"
    shared_dir: "{{ lookup('env', 'SHARED_DIR') | default('', true) }}"
  tasks:
    - name: Fail if no IPv4 or IPv6 address to change
      ansible.builtin.fail:
        msg: "No IPv4 or IPv6 address to change"
      when:
        - change_ipv4 | bool == false
        - change_ipv6 | bool == false

    - name: Find all kubeconfig files
      ansible.builtin.find:
        paths: "{{ ansible_env.KUBECONFIG }}"
        file_type: file
      register: kubeconfigs

    - name: Fail if no kubeconfig files are found
      ansible.builtin.fail:
        msg: "There should be exactly one kubeconfig file in {{ ansible_env.KUBECONFIG }}, but found {{ kubeconfigs.matched }}"
      when: kubeconfigs.matched != 1

    - name: Set kubeconfig file
      ansible.builtin.set_fact:
        kubeconfig_file: "{{ kubeconfigs.files[0].path }}"

    - name: Wait until IPConfig condition Idle is True
      ansible.builtin.command:
        cmd: "oc --kubeconfig {{ kubeconfig_file }} wait --for=condition=Idle --timeout=10m ipconfig ipconfig"
      register: ipc_idle_wait
      failed_when: ipc_idle_wait.rc != 0

    - name: Fetch current IPConfig CR
      ansible.builtin.command:
        cmd: "oc --kubeconfig {{ kubeconfig_file }} get ipconfig ipconfig -o json"
      register: ipc_get

    - name: Parse IPConfig JSON
      ansible.builtin.set_fact:
        ipc: "{{ ipc_get.stdout | from_json }}"

    - name: Extract IPv4/IPv6 status fields (if present)
      ansible.builtin.set_fact:
        ipv4_address: "{{ ipc.status.network.clusterNetwork.ipv4.address | default('', true) }}"
        ipv4_machine_cidr: "{{ ipc.status.network.clusterNetwork.ipv4.machineNetwork | default('', true) }}"
        ipv4_prefix: "{{ (ipc.status.network.clusterNetwork.ipv4.machineNetwork | default('') ).split('/') | last | default('') }}"
        ipv4_dns: "{{ ipc.status.network.hostNetwork.ipv4.dnsServer | default('', true) }}"
        ipv4_gw: "{{ ipc.status.network.hostNetwork.ipv4.gateway | default('', true) }}"
        ipv6_address: "{{ ipc.status.network.clusterNetwork.ipv6.address | default('', true) }}"
        ipv6_machine_cidr: "{{ ipc.status.network.clusterNetwork.ipv6.machineNetwork | default('', true) }}"
        ipv6_prefix: "{{ (ipc.status.network.clusterNetwork.ipv6.machineNetwork | default('') ).split('/') | last | default('') }}"
        ipv6_dns: "{{ ipc.status.network.hostNetwork.ipv6.dnsServer | default('', true) }}"
        ipv6_gw: "{{ ipc.status.network.hostNetwork.ipv6.gateway | default('', true) }}"

    - name: Compute new IPv4 address
      when:
        - change_ipv4 | bool
        - ipv4_address | length > 0
      ansible.builtin.shell: |
        python3 - "{{ ipv4_address }}" "{{ ipv4_machine_cidr }}" << 'PY'
        import ipaddress
        import sys

        ip_raw = sys.argv[1].strip()
        cidr = sys.argv[2].strip()
        ip = ip_raw.split('/')[0]
        try:
            ip_obj = ipaddress.ip_address(ip)
            net = ipaddress.ip_network(cidr, strict=False)
            candidate_plus = ip_obj + 1
            if candidate_plus in net:
                # Avoid selecting network/broadcast on IPv4
                if isinstance(net, ipaddress.IPv4Network) and (candidate_plus == net.network_address or candidate_plus == net.broadcast_address):
                    candidate_minus = ip_obj - 1
                    if candidate_minus in net and candidate_minus not in (net.network_address, net.broadcast_address):
                        print(str(candidate_minus))
                    else:
                        print(str(ip_obj))
                else:
                    print(str(candidate_plus))
            else:
                candidate_minus = ip_obj - 1
                if candidate_minus in net:
                    if isinstance(net, ipaddress.IPv4Network) and (candidate_minus == net.network_address or candidate_minus == net.broadcast_address):
                        print(str(ip_obj))
                    else:
                        print(str(candidate_minus))
                else:
                    print(str(ip_obj))
        except Exception:
            print(ip)
        PY
      register: ipv4_new_ip
      changed_when: false

    - name: Compute new IPv6 address
      when:
        - change_ipv6 | bool
        - ipv6_address | length > 0
      ansible.builtin.shell: |
        python3 - "{{ ipv6_address }}" "{{ ipv6_machine_cidr }}" << 'PY'
        import ipaddress
        import sys

        ip = sys.argv[1].strip()
        cidr = sys.argv[2].strip()
        try:
            ip_obj = ipaddress.ip_address(ip)
            net = ipaddress.ip_network(cidr, strict=False)
            candidate_plus = ip_obj + 1
            if candidate_plus in net:
                print(str(candidate_plus))
            else:
                candidate_minus = ip_obj - 1
                if candidate_minus in net:
                    print(str(candidate_minus))
                else:
                    print(str(ip_obj))
        except Exception:
            print(ip)
        PY
      register: ipv6_new_ip
      changed_when: false

    - name: Build spec patch
      ansible.builtin.set_fact:
        patch_spec: "{{ {'stage': 'Config'} }}"

    - name: Add IPv4 spec to patch
      when:
        - change_ipv4 | bool
        - ipv4_address | length > 0
        - ipv4_machine_cidr | length > 0
        - ipv4_prefix | length > 0
      ansible.builtin.set_fact:
        patch_spec: >-
          {{ patch_spec | combine({
            'ipv4': {
              'address': (ipv4_new_ip.stdout | trim),
              'machineNetwork': ipv4_machine_cidr,
              'gateway': ipv4_gw,
              'dnsServer': ipv4_dns
            }
          }, recursive=True) }}

    - name: Add IPv6 spec to patch
      when:
        - change_ipv6 | bool
        - ipv6_address | length > 0
        - ipv6_machine_cidr | length > 0
        - ipv6_prefix | length > 0
      ansible.builtin.set_fact:
        patch_spec: >-
          {{ patch_spec | combine({
            'ipv6': {
              'address': (ipv6_new_ip.stdout | trim),
              'machineNetwork': ipv6_machine_cidr,
              'gateway': ipv6_gw,
              'dnsServer': ipv6_dns
            }
          }, recursive=True) }}

    - name: Show patch body
      ansible.builtin.debug:
        var: patch_spec

    - name: Write original IPv4 address to shared dir
      ansible.builtin.copy:
        dest: "{{ shared_dir }}/ipconfig_ipv4_old"
        content: "{{ ipv4_address | default('', true) | trim }}\n"
      delegate_to: localhost

    - name: Write new IPv4 address to shared dir
      when:
        - change_ipv4 | bool
        - ipv4_address | length > 0
      ansible.builtin.copy:
        dest: "{{ shared_dir }}/ipconfig_ipv4_new"
        content: "{{ ipv4_new_ip.stdout | default('', true) | trim }}\n"
      delegate_to: localhost

    - name: Write original IPv6 address to shared dir
      ansible.builtin.copy:
        dest: "{{ shared_dir }}/ipconfig_ipv6_old"
        content: "{{ ipv6_address | default('', true) | trim }}\n"
      delegate_to: localhost

    - name: Write new IPv6 address to shared dir
      when:
        - change_ipv6 | bool
        - ipv6_address | length > 0
      ansible.builtin.copy:
        dest: "{{ shared_dir }}/ipconfig_ipv6_new"
        content: "{{ ipv6_new_ip.stdout | default('', true) | trim }}\n"
      delegate_to: localhost

    - name: Apply merge patch to IPConfig
      ansible.builtin.command:
        cmd: >-
          oc --kubeconfig {{ kubeconfig_file }} patch ipconfig ipconfig --type=merge
          -p {{ {'spec': patch_spec} | to_json | quote }}
      register: patch_result

    - name: Find openshift dnsmasq config file
      become: true
      ansible.builtin.find:
        paths: /etc/NetworkManager/dnsmasq.d
        patterns: "openshift-*"
        file_type: file
      register: dnsmasq_conf_files

    - name: Fail if the amount of dnsmasq config files is not exactly one
      ansible.builtin.fail:
        msg: "There should be exactly one dnsmasq config file in /etc/NetworkManager/dnsmasq.d, but found {{ dnsmasq_conf_files.matched }}"
      when: dnsmasq_conf_files.matched != 1

    - name: Set dnsmasq config path
      ansible.builtin.set_fact:
        dnsmasq_conf_path: "{{ dnsmasq_conf_files.files[0].path }}"

    - name: Update dnsmasq config with new IPv4 address
      when:
        - change_ipv4 | bool
        - ipv4_address | length > 0
      become: true
      ansible.builtin.replace:
        path: "{{ dnsmasq_conf_path }}"
        regexp: "{{ ipv4_address | default('', true) | trim }}"
        replace: "{{ ipv4_new_ip.stdout | default('', true) | trim }}"
      register: dnsmasq_ipv4_replaced

    - name: Update dnsmasq config with new IPv6 address
      when:
        - change_ipv6 | bool
        - ipv6_address | length > 0
      become: true
      ansible.builtin.replace:
        path: "{{ dnsmasq_conf_path }}"
        regexp: "{{ ipv6_address | default('', true) | trim }}"
        replace: "{{ ipv6_new_ip.stdout | default('', true) | trim }}"
      register: dnsmasq_ipv6_replaced

    - name: Restart NetworkManager to apply dnsmasq changes
      become: true
      ansible.builtin.service:
        name: NetworkManager
        state: restarted

    - name: Wait for ConfigCompleted condition
      ansible.builtin.command:
        cmd: >-
          oc --kubeconfig {{ kubeconfig_file }} get ipconfig ipconfig
          -ojsonpath='{.status.conditions[?(@.type=="ConfigCompleted")].status}'
      register: wait_result
      retries: 60
      delay: 30
      until: wait_result.rc == 0 and (wait_result.stdout | trim) == "True"

    - name: Fail if ConfigCompleted did not become True
      ansible.builtin.fail:
        msg: "ConfigCompleted condition was not reached in time"
      when: wait_result.rc != 0
PLAYBOOK

ansible-playbook -i "${ANSIBLE_INVENTORY}" ip-config.yaml