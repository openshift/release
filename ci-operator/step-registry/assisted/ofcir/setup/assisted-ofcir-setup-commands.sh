#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted ofcir setup command ************"

PACKET_CONF="$SHARED_DIR/packet-conf.sh"
CIRFILE="$SHARED_DIR/cir"
SSH_KEY_FILE="$CLUSTER_PROFILE_DIR/packet-ssh-key"
ANSIBLE_CONFIG_FILE="${SHARED_DIR}/ansible.cfg"

if [[ ! -f "$CIRFILE" ]]; then
    echo "Error: CIR file not found at $CIRFILE"
    exit 1
fi

if [[ ! -f "$PACKET_CONF" ]]; then
    echo "Error: packet-conf.sh not found at $PACKET_CONF"
    exit 1
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH key file not found at $SSH_KEY_FILE"
    exit 1
fi

echo "executing packet-conf.sh..."
# shellcheck disable=SC1090
source "$PACKET_CONF"

export SSH_KEY_FILE="$SSH_KEY_FILE"

if [[ -z "${IP:-}" ]]; then
    IP=$(jq -r '.ip' "$CIRFILE")
fi
export IP

mkdir -p build/ansible
cd build/ansible

cat > prepare-ansible.yaml <<-EOF
- name: Prepare locally
  hosts: localhost
  collections:
    - community.general
  gather_facts: no
  vars:
    ansible_remote_tmp: ../tmp
    SHARED_DIR: "{{ lookup('env', 'SHARED_DIR') }}"
  tasks:
    - name: Check if ansible inventory exists
      ansible.builtin.stat:
        path: "{{ SHARED_DIR }}/inventory"
      register: inventory
    - name: Create default ansible inventory
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/inventory"
        content: |
          [primary]
          primary-{{ lookup('env', 'IP') }} ansible_host={{ lookup('env', 'IP') }} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file={{ lookup('env', 'SSH_KEY_FILE') }} ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
      when: not inventory.stat.exists
    - name: Create ssh config file
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/ssh_config"
        content: |
          Host ci_machine
            User root
            HostName {{ lookup('env', 'IP') }}
            ConnectTimeout 5
            StrictHostKeyChecking no
            ServerAliveInterval 90
            LogLevel ERROR
            IdentityFile {{ lookup('env', 'SSH_KEY_FILE') }}
            ConnectionAttempts 10
    - name: Create ansible configuration
      ansible.builtin.copy:
        dest: "{{ SHARED_DIR }}/ansible.cfg"
        content: |
          [defaults]
          callback_whitelist = profile_tasks
          host_key_checking = False

          verbosity = 2
          stdout_callback = yaml
          bin_ansible_callbacks = True

          [ssh_connection]
          retries = 10
EOF

ansible-playbook prepare-ansible.yaml
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG_FILE}"

cat > ensure-memory.yaml <<-"EOF"
- name: Make sure inventory contains at least one host
  hosts: localhost
  tasks:
    - name: Fail if inventory is empty
      ansible.builtin.fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all|length == 0
      
- name: Ensure minimum total memory (RAM + swap)
  hosts: all
  gather_facts: true

  vars:
    required_memory_gib: "{{ lookup('env', 'REQUIRED_MEMORY_GIB') | int }}"
    swapfile_basename: swapfile-ci

  tasks:
    - name: Determine mount with most available space
      ansible.builtin.set_fact:
        target_mount: "{{ ansible_mounts | sort(attribute='size_available', reverse=true) | first }}"

    - name: Set swapfile_path on largest filesystem
      ansible.builtin.set_fact:
        swapfile_path: "{{ (target_mount.mount | regex_replace('/$','') + '/' + swapfile_basename) | trim }}"

    - name: Debug chosen mount and swapfile path
      ansible.builtin.debug:
        msg:
          - "Using mount point {{ target_mount.mount }} with {{ (target_mount.size_available/1024/1024/1024) | round(2) }} GB free"
          - "Swapfile will be created at {{ swapfile_path }}"

    - name: Check for fallocate binary
      ansible.builtin.stat:
        path: /usr/bin/fallocate
      register: fallocate_bin

    - name: Compute memory facts
      ansible.builtin.set_fact:
        mem_total_mb: "{{ ansible_memtotal_mb | int }}"
        swap_total_mb: "{{ ansible_swaptotal_mb | int }}"

    - name: Calculate needed swap
      ansible.builtin.set_fact:
        needed_mb: "{{ (required_memory_gib | int * 1024) - (mem_total_mb | int + swap_total_mb | int) }}"

    - name: Skip tasks if no additional swap needed
      ansible.builtin.debug:
        msg: "No additional swap needed (current total ≥ {{ required_memory_gib }} GiB)."
      when: "(needed_mb | int) <= 0"

    - name: Create swap file using fallocate
      ansible.builtin.command: fallocate -l {{ needed_mb | int }}M {{ swapfile_path }}
      args:
        creates: "{{ swapfile_path }}"
      when: "(needed_mb | int) > 0 and fallocate_bin.stat.exists"

    - name: Create swap file using dd fallback
      ansible.builtin.command: dd if=/dev/zero of={{ swapfile_path }} bs=1M count={{ needed_mb | int }}
      args:
        creates: "{{ swapfile_path }}"
      when: "(needed_mb | int) > 0 and not fallocate_bin.stat.exists"

    - name: Secure swap file permissions
      ansible.builtin.file:
        path: "{{ swapfile_path }}"
        owner: root
        group: root
        mode: '0600'
      when: "(needed_mb | int) > 0"

    - name: Format the swap file
      ansible.builtin.command: mkswap {{ swapfile_path }}
      when: "(needed_mb | int) > 0"

    - name: Activate the swap file
      ansible.builtin.command: swapon {{ swapfile_path }}
      when: "(needed_mb | int) > 0"

    - name: Ensure swap file entry in fstab
      ansible.builtin.mount:
        name: none
        src: "{{ swapfile_path }}"
        fstype: swap
        opts: sw
        dump: 0
        passno: 0
        state: present
      when: "(needed_mb | int) > 0"

    - name: Display final memory, swap, filesystem uand block device layout
      ansible.builtin.shell: |
        echo '=== Memory & Swap Usage ==='
        free -h | column -t
        echo
        echo '=== Filesystem Usage ==='
        df -h --output=source,size,used,avail,pcent,target | column -t
        echo '=== Block Device Layout ==='
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | column -t
      register: final_mem_info
      changed_when: false
    
    - name: Show final summary
      ansible.builtin.debug:
        var: final_mem_info.stdout_lines

EOF

ansible-playbook ensure-memory.yaml -i "${SHARED_DIR}/inventory"

cat > ensure-network-manager-dns-servers.yaml <<-"EOF"
- name: Make sure inventory contains at least one host
  hosts: localhost
  tasks:
    - name: Fail if inventory is empty
      ansible.builtin.fail:
        msg: "[ERROR] Empty inventory. No host available."
      when: groups.all|length == 0
      
- name: Configure NetworkManager DNS servers
  hosts: all
  gather_facts: false
  tasks:
    - name: Extract DNS servers from /etc/resolv.conf
      ansible.builtin.shell: |
        awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd "," -
      register: dns_servers
      changed_when: false

    - name: Configure NetworkManager to use those DNS servers
      ansible.builtin.ini_file:
        dest: /etc/NetworkManager/conf.d/dns-servers.conf
        section: 'global-dns-domain-*'
        option: servers
        value: "{{ dns_servers.stdout }}"
        create: yes

    - name: Reload NetworkManager to pick up new DNS settings
      ansible.builtin.systemd:
        name: NetworkManager
        state: reloaded

EOF

ansible-playbook ensure-network-manager-dns-servers.yaml -i "${SHARED_DIR}/inventory"