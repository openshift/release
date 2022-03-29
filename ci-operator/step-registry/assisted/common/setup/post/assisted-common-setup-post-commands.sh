#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup post command ************"

mkdir -p build/ansible
cd build/ansible

# Get packet | vsphere configuration
# shellcheck source=/dev/null
set +e
source "${SHARED_DIR}/packet-conf.sh"
source "${SHARED_DIR}/ci-machine-config.sh"
set -e

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

cat << EOF > inventory
[all]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${SSH_KEY_FILE} ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
EOF

cat > run_post_playbook.yaml <<-EOF
- name: Run post-install commands
  hosts: all
  vars:
    POST_INSTALL_COMMANDS: "{{ lookup('env', 'POST_INSTALL_COMMANDS') | default('#empty script', True) }}"
  tasks:
  - name: create a config file
    ansible.builtin.copy:
      dest: /root/assisted-post-install.sh
      content: |
        {{ POST_INSTALL_COMMANDS }}
        echo "Finish running post installation script"
  - name: Run post installation command
    ansible.builtin.shell: |
        set -xeuo pipefail
        cd /home/assisted
        source /root/config.sh
        echo "export KUBECONFIG=/home/assisted/build/kubeconfig" >> /root/.bashrc
        export KUBECONFIG=/home/assisted/build/kubeconfig
        source "/root/assisted-post-install.sh"
EOF

ansible-playbook run_post_playbook.yaml -i inventory
