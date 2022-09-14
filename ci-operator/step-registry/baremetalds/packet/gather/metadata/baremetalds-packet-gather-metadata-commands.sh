#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_TYPE}" != *"packet"* ]]; then
  echo "No need to gather Equinix metadata for cluster type ${CLUSTER_TYPE}"
  exit 0
fi

echo "************ baremetalds packet gather metadata command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

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

ansible-playbook gather_equinix_metadata.yaml -i ${SHARED_DIR}/inventory -vv
