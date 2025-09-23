#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ ofcir gather command ************"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh
source "${REPO_ROOT}/ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh"

assisted_load_host_contract

CIRFILE="$SHARED_DIR/cir"
ANSIBLE_CFG="$SHARED_DIR/ansible.cfg"

if [[ ! -f "$CIRFILE" ]]; then
    echo "Error: CIR file not found at $CIRFILE"
    exit 1
fi

if [[ -z "${SSH_KEY_FILE:-}" ]]; then
    echo "Error: SSH_KEY_FILE not defined in ${SHARED_DIR}/ci-machine-config.sh"
    exit 1
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH key file not found at $SSH_KEY_FILE"
    exit 1
fi

echo "cir file content:"
cat "$CIRFILE" > "$ARTIFACT_DIR/cir.json"

export ANSIBLE_CONFIG="$ANSIBLE_CFG"
export SSH_KEY_FILE
export SSH_USER
export IP

IBM_CLOUD_API_KEY_FILE="${CLUSTER_PROFILE_DIR}/ibm-cloud-api-key"
if [[ -f "$IBM_CLOUD_API_KEY_FILE" ]]; then
    IBM_CLOUD_API_KEY=$(<"$IBM_CLOUD_API_KEY_FILE")
    export IBM_CLOUD_API_KEY
fi

PROVIDER=$(cat $CIRFILE | jq -r '.provider')
echo "Provider: $PROVIDER"

mkdir -p build/ansible
cd build/ansible

cat > prepare-ansible.yaml <<-EOF
- name: Prepare locally
  hosts: localhost
  collections:
    - community.general
  gather_facts: no
  vars:
    ansible_remote_tmp: ../tmp
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
  tasks:
    - name: Check if ansible inventory exists
      stat:
        path: "{{ SHARED_DIR }}/inventory"
      register: inventory
    - name: Create default ansible inventory
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/inventory"
        content: |
          [primary]
          primary-{{ lookup('env', 'IP') }} ansible_host={{ lookup('env', 'IP') }} ansible_user={{ lookup('env', 'SSH_USER') | default('root') }} ansible_ssh_user={{ lookup('env', 'SSH_USER') | default('root') }} ansible_ssh_private_key_file={{ lookup('env', 'SSH_KEY_FILE') }} ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
      when: not inventory.stat.exists
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

ansible-playbook prepare-ansible.yaml

cat > gather_equinix_metadata.yaml <<-EOF
- name: Make sure inventory contains at least one host
  hosts: localhost
  tasks:
    - fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all|length == 0

- name: Gather Equinix metadata and store it for CI data enrichment
  hosts: all
  tasks:
    - name: Fetch Equinix metadata
      ansible.builtin.uri:
        url: "https://metadata.platformequinix.com/metadata"
        return_content: yes
      register: equinix_metadata
      until: equinix_metadata.status == 200
      retries: 5
      delay: 5
      no_log: true
    - name: Filter and dump equinix metadata
      local_action:
        module: ansible.builtin.copy
        content: "{% set removed = equinix_metadata.json.pop('ssh_keys') %}{{ equinix_metadata.json | to_nice_json }}"
        dest: "{{ lookup('env', 'ARTIFACT_DIR') }}/equinix-metadata.json"
EOF

if [[ "$PROVIDER" = "equinix" ]]; then
    echo "Provider is equinix, gathering metadata..."
    ansible-playbook gather_equinix_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
    exit 0
fi

cat > gather_ibm_classic_metadata.yaml <<-'EOF'
- name: Make sure inventory contains at least one host
  hosts: localhost
  tasks:
    - fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all|length == 0

- name: Gather IBM Classic (SoftLayer) Bare Metal metadata
  hosts: all
  gather_facts: no
  vars:
    sl_api_url: "https://api.service.softlayer.com/rest/v3.1"
    api_key: "{{ lookup('env','IBM_CLOUD_API_KEY') }}"
  tasks:
    - name: Fetch this server's SoftLayer resource ID
      ansible.builtin.uri:
        url: "{{ sl_api_url }}/SoftLayer_Resource_Metadata/getId.json"
        method: GET
        return_content: yes
      register: sl_metadata_id
      no_log: true

    - name: Fetch full hardware details
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

    - name: Combine all metadata into one structure
      ansible.builtin.set_fact:
        ibm_metadata:
          resourceId: "{{ sl_metadata_id.json }}"
          hardware: "{{ sl_hw.json }}"
          operatingSystem: "{{ sl_os.json }}"
          datacenter: "{{ sl_datacenter.json }}"

    - name: Write combined IBM metadata to artifact dir
      local_action:
        module: ansible.builtin.copy
        dest: "{{ lookup('env','ARTIFACT_DIR') }}/ibm-classic-metadata.json"
        content: "{{ ibm_metadata | to_nice_json }}"

EOF

if [[ "$PROVIDER" = "ibmcloud" ]]; then
    echo "Provider is IBM Classic, gathering metadata..."
    ansible-playbook gather_ibm_classic_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
fi

cat > gather_aws_metadata.yaml <<-'EOF'
- name: Make sure inventory contains at least one host
  hosts: localhost
  tasks:
    - fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all | length == 0

- name: Gather AWS EC2 instance metadata
  hosts: all
  gather_facts: no
  tasks:
    - name: Get IMDSv2 token from EC2 metadata service
      ansible.builtin.uri:
        url: "http://169.254.169.254/latest/api/token"
        method: PUT
        headers:
          "X-aws-ec2-metadata-token-ttl-seconds": "21600"
        return_content: yes
      register: aws_metadata_token
      no_log: true

    - name: Fetch EC2 instance identity document
      ansible.builtin.uri:
        url: "http://169.254.169.254/latest/dynamic/instance-identity/document"
        return_content: yes
        headers:
          "X-aws-ec2-metadata-token": "{{ aws_metadata_token.content }}"
      register: aws_metadata_doc
      no_log: true

    - name: Write AWS metadata JSON to artifact directory
      local_action:
        module: ansible.builtin.copy
        dest: "{{ lookup('env','ARTIFACT_DIR') }}/aws-metadata.json"
        content: "{{ aws_metadata_doc.content }}"

EOF

if [[ "$PROVIDER" = "aws" ]]; then
    echo "Provider is AWS, gathering metadata..."
    ansible-playbook gather_aws_metadata.yaml -i "${SHARED_DIR}/inventory" -vv
fi
