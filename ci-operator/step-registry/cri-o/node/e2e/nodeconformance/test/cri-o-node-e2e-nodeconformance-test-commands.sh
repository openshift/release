#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x "${SHARED_DIR}/login_script.sh"
"${SHARED_DIR}/login_script.sh"

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" "${IP}" -- bash - <<EOF
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    cat <<'PLAYBOOK' > e2e-nodeconformance.yml
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

    - name: Run NodeConformance tests
      become: yes
      shell: |
        export CONTAINER_RUNTIME_ENDPOINT="unix:///var/run/crio/crio.sock" && \
        make test-e2e-node FOCUS="\[NodeConformance\]" SKIP="\[sig-node\]\s*Summary\s*API\s*\[NodeConformance\]|\[sig-node\]\s*MirrorPodWithGracePeriod\s*when\s*create\s*a\s*mirror\s*pod\s*and\s*the\s*container\s*runtime\s*is\s*temporarily\s*down\s*during\s*pod\s*termination\s*\[NodeConformance\]\s*\[Serial\]\s*\[Disruptive\]" TEST_ARGS="--kubelet-flags='--cgroup-driver=systemd --cgroup-root=/ --cgroups-per-qos=true --runtime-cgroups=/system.slice/crio.service --kubelet-cgroups=/system.slice/kubelet.service'"
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
    ansible-playbook e2e-nodeconformance.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv --tags setup,e2e-node
EOF