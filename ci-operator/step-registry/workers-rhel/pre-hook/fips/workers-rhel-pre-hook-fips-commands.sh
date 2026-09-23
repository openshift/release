#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

export PLATFORM=""
PLATFORM=$(oc get infrastructure cluster -o=jsonpath='{.status.platform}')
cat >  scaleup-pre-hook-enable-fips.yaml <<-'EOF'
- name: enable fips for rhel8
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false

  vars:
    platform: "{{ lookup('env', 'PLATFORM') }}"
    platform_version: "{{ lookup('env', 'PLATFORM_VERSION') }}"
    major_platform_version: "{{ platform_version[:1] }}"

  tasks:
  # Enable fips for RHEL-8 node
  - block:
    # RHUIv2/RHUIv3 uses a TLS crypto algorithm that's not accepted in FIPS mode on RHEL8. Need to update to RHUIv4.
    # Details seen from https://issuetracker.google.com/issues/197769045
    - name: Update google-rhui-client-rhel8 package to resolve the CA issue for FIPS
      yum:
        name: google-rhui-client-rhel8
        state: latest
      when:
      - platform == 'GCP'

    - name: enable fips - rhel8
      shell: fips-mode-setup --enable
      register: fip_mode_enable
      failed_when: fip_mode_enable is not search("FIPS mode will be enabled")

    - name: Restart host - rhel8
      reboot:
        reboot_timeout: 300

    - name: check whether fips enabled or not for rhel8
      shell: fips-mode-setup --check
      register: fips_mode_check
      failed_when: fips_mode_check is not search('FIPS mode is enabled')
    when: major_platform_version == "8"
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" scaleup-pre-hook-enable-fips.yaml -vvv
