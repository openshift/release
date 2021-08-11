#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet teardown command ************"

# Run Ansible playbook
cd
cat > packet-teardown.yaml <<-EOF
- name: teardown Packet host
  hosts: localhost
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    - slackhook_path: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}/slackhook"
    - packet_credentials_dir: "{{ '/var/run/secrets/packet/' + lookup('env', 'PACKET_ACCOUNT') + '/' }}"

  tasks:

  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: cluster_type != "packet"

  - name: remove Packet host with error handling
    block:
    - name: remove Packet host {{ packet_hostname }}
      packet_device:
        auth_token: "{{ lookup('file', packet_credentials_dir + 'packet-auth-token') }}"
        project_id: "{{ lookup('file', packet_credentials_dir + 'packet-project-id') }}"
        hostnames: "{{ packet_hostname }}"
        state: absent
      retries: 5
      delay: 120
      register: hosts
      until: hosts.failed == false
      no_log: true
    rescue:
    - name: Send notification message via Slack in case of failure
      slack:
        token: "{{ 'T027F3GAJ/B011TAG710V/' + lookup('file', slackhook_path) }}"
        msg: "Packet failure: *Teardown*\nHostname: *{{ packet_hostname }}*\nError msg: {{ ansible_failed_result.msg }}\n"
        username: "OpenShift CI Packet"
        color: warning
        icon_emoji: ":failed:"
    - name: fail the play
      fail:
        msg: "Packet teardown failed."
EOF

ansible-playbook packet-teardown.yaml -e "packet_hostname=${PACKET_ACCOUNT}-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}"  |& gawk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0; fflush(); }'
