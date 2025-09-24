#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/host-contract/host-contract.sh"

host_contract::load

CIRFILE="${HOST_PRIMARY_METADATA_PATH:-${SHARED_DIR}/cir}"
if [[ -f "$CIRFILE" ]]; then
    cp "$CIRFILE" "$ARTIFACT_DIR/cir.json"
fi

host_contract::write_inventory "${SHARED_DIR}/inventory"
host_contract::write_ansible_cfg "${SHARED_DIR}/ansible.cfg"
host_contract::write_ssh_config "${SHARED_DIR}/ssh_config"

IP="$HOST_SSH_HOST"
export IP
export HOST_SSH_USER="${HOST_SSH_USER:-root}"
export HOST_SSH_PORT="${HOST_SSH_PORT:-22}"
export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
export SSH_KEY_FILE="$HOST_SSH_KEY_FILE"

IBM_CLOUD_API_KEY_FILE="${CLUSTER_PROFILE_DIR}/ibm-cloud-api-key"
if [[ -f "$IBM_CLOUD_API_KEY_FILE" ]]; then
    IBM_CLOUD_API_KEY=$(<"$IBM_CLOUD_API_KEY_FILE")
    export IBM_CLOUD_API_KEY
fi

PROVIDER="${HOST_PROVIDER:-ofcir}"
if [[ -f "$CIRFILE" ]]; then
    PROVIDER=$(jq -r '.provider // "ofcir"' "$CIRFILE" 2>/dev/null || echo "ofcir")
fi
mkdir -p build/ansible
cd build/ansible

cat > prepare-ansible.yaml <<'PLAY'
- name: Prepare locally
  hosts: localhost
  collections:
    - community.general
  gather_facts: no
  vars:
    ansible_remote_tmp: ../tmp
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
  tasks:
    - name: Ensure ansible inventory exists
      stat:
        path: "{{ SHARED_DIR }}/inventory"
      register: inventory
    - name: Create default ansible inventory
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/inventory"
        content: |
          [primary]
          primary ansible_host={{ lookup('env', 'IP') }} ansible_user={{ lookup('env', 'HOST_SSH_USER') | default('root') }} ansible_ssh_user={{ lookup('env', 'HOST_SSH_USER') | default('root') }} ansible_ssh_private_key_file={{ lookup('env', 'SSH_KEY_FILE') }} ansible_port={{ lookup('env', 'HOST_SSH_PORT') | default(22) }} ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
PLAY

ansible-playbook prepare-ansible.yaml

cat > gather_equinix_metadata.yaml <<'PLAY'
- name: Ensure inventory has hosts
  hosts: localhost
  tasks:
    - ansible.builtin.fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all | length == 0

- name: Gather Equinix metadata
  hosts: all
  tasks:
    - name: Fetch metadata
      ansible.builtin.uri:
        url: "https://metadata.platformequinix.com/metadata"
        return_content: yes
      register: equinix_metadata
      until: equinix_metadata.status == 200
      retries: 5
      delay: 5
      no_log: true
    - name: Store metadata locally
      local_action:
        module: ansible.builtin.copy
        content: "{% set _ = equinix_metadata.json.pop('ssh_keys') %}{{ equinix_metadata.json | to_nice_json }}"
        dest: "{{ lookup('env', 'ARTIFACT_DIR') }}/equinix-metadata.json"
PLAY

if [[ "$PROVIDER" == "equinix" ]]; then
    ansible-playbook gather_equinix_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
    exit 0
fi

cat > gather_ibm_classic_metadata.yaml <<'PLAY'
- name: Ensure inventory has hosts
  hosts: localhost
  tasks:
    - ansible.builtin.fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all | length == 0

- name: Gather IBM Classic metadata
  hosts: all
  gather_facts: no
  vars:
    sl_api_url: "https://api.service.softlayer.com/rest/v3.1"
    api_key: "{{ lookup('env', 'IBM_CLOUD_API_KEY') }}"
  tasks:
    - name: Fetch resource ID
      ansible.builtin.uri:
        url: "{{ sl_api_url }}/SoftLayer_Resource_Metadata/getId.json"
        method: GET
        return_content: yes
      register: sl_metadata_id
      no_log: true
    - name: Fetch hardware details
      ansible.builtin.uri:
        url: "{{ sl_api_url }}/SoftLayer_Hardware_Server/{{ sl_metadata_id.json }}/getObject.json"
        method: GET
        user: apikey
        password: "{{ api_key }}"
        force_basic_auth: yes
        return_content: yes
      register: sl_hw
      no_log: true
    - name: Fetch operating system details
      ansible.builtin.uri:
        url: "{{ sl_api_url }}/SoftLayer_Hardware_Server/{{ sl_metadata_id.json }}/getOperatingSystem.json"
        method: GET
        user: apikey
        password: "{{ api_key }}"
        force_basic_auth: yes
        return_content: yes
      register: sl_os
      no_log: true
    - name: Fetch datacenter information
      ansible.builtin.uri:
        url: "{{ sl_api_url }}/SoftLayer_Resource_Metadata/getDatacenter.json"
        method: GET
        return_content: yes
      register: sl_datacenter
      no_log: true
    - name: Store metadata
      local_action:
        module: ansible.builtin.copy
        dest: "{{ lookup('env','ARTIFACT_DIR') }}/ibm-classic-metadata.json"
        content: "{{ {
          'resourceId': sl_metadata_id.json,
          'hardware': sl_hw.json,
          'operatingSystem': sl_os.json,
          'datacenter': sl_datacenter.json
        } | to_nice_json }}"
PLAY

if [[ "$PROVIDER" == "ibmcloud" ]]; then
    ansible-playbook gather_ibm_classic_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
fi

cat > gather_aws_metadata.yaml <<'PLAY'
- name: Ensure inventory has hosts
  hosts: localhost
  tasks:
    - ansible.builtin.fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all | length == 0

- name: Gather AWS metadata
  hosts: all
  gather_facts: no
  tasks:
    - name: Acquire IMDSv2 token
      ansible.builtin.uri:
        url: "http://169.254.169.254/latest/api/token"
        method: PUT
        headers:
          X-aws-ec2-metadata-token-ttl-seconds: "21600"
        return_content: yes
      register: aws_metadata_token
      no_log: true
    - name: Fetch identity document
      ansible.builtin.uri:
        url: "http://169.254.169.254/latest/dynamic/instance-identity/document"
        return_content: yes
        headers:
          X-aws-ec2-metadata-token: "{{ aws_metadata_token.content }}"
      register: aws_metadata_doc
      no_log: true
    - name: Store metadata
      local_action:
        module: ansible.builtin.copy
        dest: "{{ lookup('env','ARTIFACT_DIR') }}/aws-metadata.json"
        content: "{{ aws_metadata_doc.content }}"
PLAY

if [[ "$PROVIDER" == "aws" ]]; then
    ansible-playbook gather_aws_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
fi
