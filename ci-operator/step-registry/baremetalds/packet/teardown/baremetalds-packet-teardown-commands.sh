#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet teardown command ************"

# This is required to be able to SSH.
# shellcheck source=/dev/null
source "${SHARED_DIR}/fix-uid.sh"

# Run Ansible playbook
cd
cat > packet-teardown.yaml <<-EOF
- name: teardown Packet host
  hosts: localhost
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    - slackhook_path: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}"
  vars_files:
    - "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}/.packet-kni-vars"
  tasks:

  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: cluster_type != "packet"

  - name: remove Packet host with error handling
    block:
    - name: remove Packet host {{ packet_hostname }}
      packet_device:
        auth_token: "{{ packet_auth_token }}"
        project_id: "{{ packet_project_id }}"
        hostnames: "{{ packet_hostname }}"
        state: absent
      retries: 3
      delay: 120
      register: hosts
      until: hosts.failed == false
      no_log: true
    rescue:
    - name: Send notification message via Slack in case of failure
      slack:
        token: "{{ 'T027F3GAJ/B011TAG710V/' + lookup('file', slackhook_path + '/.slackhook') }}"
        msg: 'Packet teardown failed. Error msg: {{ ansible_failed_result.msg }}'
        username: '{{ packet_hostname }}'
        color: warning
        icon_emoji: ":failed:"
    - name: fail the play
      fail:
        msg: "Packet teardown failed."
EOF

ansible-playbook packet-teardown.yaml -e "packet_hostname=ipi-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}"
