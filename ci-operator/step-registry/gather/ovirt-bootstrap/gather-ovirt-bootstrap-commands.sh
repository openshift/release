#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -o allexport

# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/ovirt.conf"


if [ "$(id -u)" -ge 500 ]; then
    echo "runner:x:$(id -u):$(id -g):,,,:/runner:/bin/bash" > /tmp/passwd
    cat /tmp/passwd >> /etc/passwd
    rm /tmp/passwd
fi

mkdir -p ~/.ssh/
chmod 700 ~/.ssh/

cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

cat <<__EOF__ >~/.ansible.cfg
[defaults]
host_key_checking = False
__EOF__

# set the PROXY_ADDRESS from the ovirt.conf secret
cat <<__EOF__ >>~/.ssh/config
StrictHostKeyChecking no
UserKnownHostsFile /dev/null

Host 192.168.2*
    Port 22
    User core
    ConnectTimeout 5
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyJump root@${PROXY_ADDRESS}
__EOF__
chmod 400 ~/.ssh/config


# Generate Ansible yaml files
cat > find_reported_address.yaml	 <<-EOF
- name: query VM Nics until reported_devices Address is found
  block:

  - ovirt_vm_info:
      auth: "{{ovirt_auth}}"  
      pattern: id="{{vm_id}}"
    register: vm_info

  - set_fact:
      vm_name: "{{vm_info['ovirt_vms'][0]['name']}}"

  - ovirt_nic_info:
      auth: "{{ovirt_auth}}"
      vm: "{{vm_name}}"
    register: vm_nics
    delegate_to: localhost

  - wait_for:
      timeout: "{{ 2 }}"
    delegate_to: localhost

  - debug: msg="{{ vm_nics }}"
  - name: list all the reported_devices for the NIC
    uri:
      url: "https://{{ ovirt_auth['url'] | urlsplit('hostname')  }}{{ vm_nics.ovirt_nics[0].href }}/reporteddevices"
      method: GET
      headers:
        Version: "4"
        Authorization: "Bearer {{ ovirt_auth['token'] }}"
        Accept: "application/json"
      status_code: 200
      validate_certs: no
    register: reported_ips
    delegate_to: localhost

  - assert:
      that: 
        - reported_ips.json.reported_device is defined
        - reported_ips.json.reported_device[0].ips.ip[0].address | ansible.utils.ipv4

  - set_fact:
      collected_address: "{{ reported_ips.json.reported_device[0].ips.ip[0].address }}"

EOF

cat > gather_bootstrap_logs.yaml	 <<-EOF
---
- name: create ocp-for-rhv CI env
  hosts: localhost
  vars:
    ovirt_engine_url: "{{ lookup('env','OVIRT_ENGINE_URL') }}"
    ovirt_engine_username: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
    ovirt_engine_password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
    ovirt_engine_hostname: "{{ ovirt_engine_url | urlsplit('hostname') }}"
    bootstrap_tfvars_conf: "{{ lookup('env','BOOTSTRAP_TFVARS') }}"
    bootstrap_conf: "{{ lookup('file', bootstrap_tfvars_conf ) | from_json }}"
    must_gather_saved_path: "{{ lookup('env','MUST_GATHER_PATH') }}"

  tasks:
    - name: download CA file from engine
      get_url:
        url: "https://{{ ovirt_engine_url | urlsplit('hostname') }}/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA"
        dest: "/tmp/ca.pem"
        validate_certs: no

    - set_fact: " vm_id={{ bootstrap_conf.bootstrap_vm_id }} "
    - name: Login to RHV
      ovirt_auth:
        url: "{{ ovirt_engine_url }}"
        username: "{{ ovirt_engine_username }}"
        password: "{{ ovirt_engine_password }}"
        ca_file: "/tmp/ca.pem"
        insecure: "true"
    - name: find bootstrap IP Address reported by oVirt vm_id
      include_tasks: find_reported_address.yml

    - debug: msg="found IP address - {{ collected_address }}"

    - name: Add bootstrap IP address
      add_host:
        hostname: '{{ collected_address }}'
        name: bootstrap
        ansible_ssh_host: '{{ collected_address }}'
        ansible_ssh_user: core    

    - block: 
        - ping: 
        - name: generating the log bundle
          command: /usr/local/bin/installer-gather.sh --id bootstrap      
        - name: fetching generated ocp log bundle
          fetch: 
            src: /var/home/core/log-bundle-bootstrap.tar.gz 
            dest: "{{must_gather_saved_path}}"
            flat: yes
      delegate_to: bootstrap

EOF

echo "######### running playbook `ansible-playbook gather_bootstrap_logs.yaml` - collecting logs from bootstrap VM  \n"
ansible-playbook gather_bootstrap_logs.yaml -e bootstrap_tfvars_conf=${SHARED_DIR}/bootstrap.tfvars.json -e must_gather_saved_path=${ARTIFACT_DIR}/log-bundle-bootstrap.tar.gz 