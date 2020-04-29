#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet teardown command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
${HOME}/fix_uid.sh

# Run Ansible playbook
cd ${HOME}
cat > packet-teardown.yaml <<-EOF
- name: teardown Packet host
  hosts: localhost
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
  vars_files:
    - "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}/.packet-kni-vars"
  tasks:

  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: cluster_type != "packet"

  - name: remove Packet host {{ packet_hostname }}
    packet_device:
      auth_token: "{{ packet_auth_token }}"
      project_id: "{{ packet_project_id }}"
      hostnames: "{{ packet_hostname }}" 
      state: absent
    no_log: true    
EOF

ansible-playbook packet-teardown.yaml -e "packet_hostname=ipi-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}"