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

cat > scaleup-pre-hook-haproxy.yaml <<-'EOF'
- name: configure haproxy for new workers
  hosts: lb
  any_errors_fatal: true
  gather_facts: false
  tasks:
  - name: get new workers ip
    set_fact:
      workerlist: "{{ groups['new_workers'] }}"

  - debug: var=workerlist

  - name: configure ingress 80 port for new workers
    lineinfile:
      line: "        server {{ item }} {{ item}}:80 check"
      insertafter: '.*:80 check$'
      dest: "/etc/haproxy/haproxy.conf"
      state: present
    with_items: "{{ workerlist }}"

  - name: configure ingress 443 port for new workers
    lineinfile:
      line: "        server {{ item }} {{ item}}:443 check"
      insertafter: '.*:443 check$'
      dest: "/etc/haproxy/haproxy.conf"
      state: present
    with_items: "{{ workerlist }}"

  - name: restart haproxy service
    systemd:
      name: haproxy
      daemon_reload: yes
      state: restarted
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" scaleup-pre-hook-haproxy.yaml -vvv
