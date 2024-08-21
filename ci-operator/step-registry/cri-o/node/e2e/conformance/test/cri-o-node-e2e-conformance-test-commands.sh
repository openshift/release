#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x "${SHARED_DIR}/login_script.sh"
"${SHARED_DIR}/login_script.sh"

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" "${IP}" -- bash - <<EOF
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    cat <<'PLAYBOOK' > e2e-node-conformance.yml
---
- hosts: localhost, all
  become: yes
  environment:
    GOPATH: /usr/go
    KUBECONFIG: /var/run/kubernetes/admin.kubeconfig
    CONTAINER_RUNTIME_ENDPOINT: "unix:///var/run/crio/crio.sock"
  vars_files:
    - "{{ playbook_dir }}/vars.yml"
  tags:
    - e2e-node
  tasks:  
    - name: build and install cri-o
      include_tasks: "build/cri-o.yml"

    - name: enable and start CRI-O
      become: yes
      systemd:
        name: crio
        state: started
        enabled: yes
        daemon_reload: yes

    - name: Disable selinux during e2e tests
      command: 'setenforce 0'

    - name: Run Conformance tests
      become: yes
      shell: |
        export CONTAINER_RUNTIME_ENDPOINT="unix:///var/run/crio/crio.sock" &&\
        make test-e2e-node FOCUS="\[Conformance\]" SKIP="\[sig-node\]\s*Pods\s*should\s*(delete\s*a\s*collection\s*of\s*pods|patch\s*a\s*pod\s*status|run\s*through\s*the\s*lifecycle\s*of\s*Pods\s*and\s*PodStatus)\s*\[Conformance\]" TEST_ARGS="--kubelet-flags='--cgroup-driver=systemd --cgroup-root=/ --cgroups-per-qos=true --runtime-cgroups=/system.slice/crio.service --kubelet-cgroups=/system.slice/kubelet.service'"
      args:
        chdir: "{{ ansible_env.GOPATH }}/src/k8s.io/kubernetes"
      async: 14400
      poll: 60
    
    - name: Re-enable SELinux after e2e tests
      command: 'setenforce 1'

    - name: Set correct permissions for artifacts
      file:
        path: "{{ artifacts }}"
        owner: deadbeef
        group: deadbeef
        mode: '0644'
        recurse: yes
      become: yes

    - name: Set directory permissions for artifacts
      file:
        path: "{{ artifacts }}"
        state: directory
        mode: '0755'
        recurse: yes
      become: yes
PLAYBOOK
    # Now run the dynamically created e2e-node.yml playbook
    ansible-playbook e2e-node-conformance.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv --tags setup,e2e-node
EOF