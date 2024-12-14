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
    
     # Install the SeLinux policy for e2e-node-kubelet on the system
    - block:
        - name: Copy e2e-node-kubelet.te
          copy:
            dest: /tmp/e2e-node-kubelet.te
            content: |
              module e2e-node-kubelet 1.0;

              require {
                type init_t;
                type kmsg_device_t;
                type container_runtime_t;
                type websm_port_t;
                type container_log_t;
                type user_tmp_t;
                type var_lib_t;
                type kernel_t;
                type http_port_t;
                type http_cache_port_t;
                type commplex_main_port_t;
                type container_file_t;
                type ephemeral_port_t;
                type unreserved_port_t;
                type us_cli_port_t;
                type var_log_t;
                class file { execute execute_no_trans map open read unlink };
                class unix_stream_socket connectto;
                class chr_file read;
                class system syslog_read;
                class tcp_socket name_connect;
                class sock_file { create rename unlink write };
                class dir rmdir;
              }

              #============= init_t ==============

              allow init_t commplex_main_port_t:tcp_socket name_connect;
              allow init_t container_file_t:sock_file { create unlink write };
              allow init_t container_log_t:file { open read unlink };
              allow init_t container_runtime_t:unix_stream_socket connectto;
              allow init_t ephemeral_port_t:tcp_socket name_connect;
              allow init_t http_cache_port_t:tcp_socket name_connect;
              allow init_t http_port_t:tcp_socket name_connect;
              allow init_t kernel_t:system syslog_read;
              allow init_t kmsg_device_t:chr_file read;
              allow init_t unreserved_port_t:tcp_socket name_connect;
              allow init_t us_cli_port_t:tcp_socket name_connect;
              allow init_t user_tmp_t:file { execute execute_no_trans map open };
              allow init_t var_lib_t:sock_file { create rename unlink };
              allow init_t var_log_t:dir rmdir;
              allow init_t websm_port_t:tcp_socket name_connect;

        - name: Convert TE file into a policy module
          shell: checkmodule -M -m -o /tmp/e2e-node-kubelet.mod /tmp/e2e-node-kubelet.te

        - name: Compile and generate policy package
          shell: semodule_package -o /tmp/e2e-node-kubelet.pp -m /tmp/e2e-node-kubelet.mod

        - name: Load e2e-node-kubelet policy package
          shell: sudo semodule -B && sudo semodule -i /tmp/e2e-node-kubelet.pp

        - name: List e2e-node-kubelet policy module
          shell: sudo semodule -l | grep e2e-node-kubelet

      always:
        - name: Clean up temporary files
          file:
            path: "{{ item }}"
            state: absent
          loop:
            - "/tmp/e2e-node-kubelet.te"
            - "/tmp/e2e-node-kubelet.mod"
            - "/tmp/e2e-node-kubelet.pp"

    - name: Run NodeConformance tests
      become: yes
      shell: |
        export CONTAINER_RUNTIME_ENDPOINT="unix:///var/run/crio/crio.sock" && \
        make test-e2e-node FOCUS="\[NodeConformance\]" SKIP="\[sig-node\]\s*Summary\s*API\s*\[NodeConformance\]|\[sig-node\]\s*MirrorPodWithGracePeriod\s*when\s*create\s*a\s*mirror\s*pod\s*and\s*the\s*container\s*runtime\s*is\s*temporarily\s*down\s*during\s*pod\s*termination\s*\[NodeConformance\]\s*\[Serial\]\s*\[Disruptive\]" TEST_ARGS="--kubelet-flags='--cgroup-driver=systemd --cgroup-root=/ --cgroups-per-qos=true --runtime-cgroups=/system.slice/crio.service --kubelet-cgroups=/system.slice/kubelet.service'"
      args:
        chdir: "{{ ansible_env.GOPATH }}/src/k8s.io/kubernetes"
      async: 14400
      poll: 60

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