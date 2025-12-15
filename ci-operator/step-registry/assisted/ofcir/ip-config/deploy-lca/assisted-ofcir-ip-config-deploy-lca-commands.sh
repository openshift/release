#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config-deploy-lca command ************"

export ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
if [[ ! -f "$ANSIBLE_CONFIG" ]]; then
    echo "Ansible config not found at: ${ANSIBLE_CONFIG}" >&2
    exit 1
fi
export ANSIBLE_CONFIG

ANSIBLE_INVENTORY="${SHARED_DIR}/inventory"
if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
    echo "Ansible inventory not found at: ${ANSIBLE_INVENTORY}" >&2
    exit 1
fi
export ANSIBLE_INVENTORY

cat > deploy-lca.yaml <<-'PLAYBOOK'
- name: Deploy lifecycle-agent operator
  hosts: primary
  gather_facts: true
  vars:
    lca_image: "{{ lookup('env', 'LCA_IMAGE') | default('', true) }}"
    lca_repo: "/home/lifecycle-agent"
    pull_secret_file: "/root/pull-secret"
  tasks:
    - name: Fail if lca image is not provided
      ansible.builtin.fail:
        msg: "No lca image provided"
      when: lca_image | length == 0

    - name: Ensure lca repository exists
      ansible.builtin.file:
        path: "{{ lca_repo }}"
        state: directory

    - name: Find all kubeconfig files
      ansible.builtin.find:
        paths: "{{ ansible_env.KUBECONFIG }}"
        file_type: file
      register: kubeconfigs

    - name: Fail if no kubeconfig files are found
      ansible.builtin.fail:
        msg: "There should be exactly one kubeconfig file in {{ ansible_env.KUBECONFIG }}, but found {{ kubeconfigs.matched }}"
      when: kubeconfigs.matched != 1

    - name: Set kubeconfig file
      ansible.builtin.set_fact:
        kubeconfig_file: "{{ kubeconfigs.files[0].path }}"

    - name: Fail if pull secret file is not found
      ansible.builtin.fail:
        msg: "Pull secret file not found at: {{ pull_secret_file }}"
      when: pull_secret_file | length == 0

    - name: Determine Go version from go.mod
      ansible.builtin.shell: "awk '/^go /{print $2; exit}' go.mod"
      args:
        chdir: "{{ lca_repo }}"
      register: go_mod_go_version
      changed_when: false

    - name: Fetch Go releases metadata
      ansible.builtin.uri:
        url: "https://go.dev/dl/?mode=json&include=all"
        return_content: true
      register: go_releases
      changed_when: false

    - name: Choose Go version to install
      ansible.builtin.set_fact:
        requested_go_version: "{{ go_mod_go_version.stdout | trim }}"
        go_releases_list: "{{ go_releases.content | from_json }}"

    - name: Select matching Go release
      ansible.builtin.set_fact:
        selected_go_release: "{{ (go_releases_list
          | selectattr('version', 'search', '^go' ~ requested_go_version ~ '(\\.|$)')
          | selectattr('stable', 'equalto', true)
          | list
          | first) }}"

    - name: Fail if no matching Go release was found
      ansible.builtin.fail:
        msg: "Could not find a Go release for version {{ requested_go_version }}"
      when: selected_go_release is not defined

    - name: Select linux-amd64 archive artifact
      ansible.builtin.set_fact:
        selected_go_file: "{{ (selected_go_release.files
          | selectattr('os', 'equalto', 'linux')
          | selectattr('arch', 'equalto', 'amd64')
          | selectattr('kind', 'equalto', 'archive')
          | list
          | first) }}"

    - name: Fail if linux-amd64 archive not found
      ansible.builtin.fail:
        msg: "No linux-amd64 archive for {{ selected_go_release.version }}"
      when: selected_go_file is not defined

    - name: Download Go archive
      ansible.builtin.get_url:
        url: "https://go.dev/dl/{{ selected_go_file.filename }}"
        dest: "/tmp/{{ selected_go_file.filename }}"
        checksum: "sha256:{{ selected_go_file.sha256 }}"

    - name: Remove existing Go installation directory
      become: true
      ansible.builtin.file:
        path: /usr/local/go
        state: absent

    - name: Install Go into /usr/local
      become: true
      ansible.builtin.unarchive:
        src: "/tmp/{{ selected_go_file.filename }}"
        dest: /usr/local
        remote_src: true

    - name: Ensure go binary is available on PATH
      become: true
      ansible.builtin.file:
        src: /usr/local/go/bin/go
        dest: /usr/local/bin/go
        state: link
        force: true

    - name: Verify Go installation
      ansible.builtin.command: "go version"
      register: go_version_out
      changed_when: false

    - name: Deploy operator using environment IMG
      ansible.builtin.shell: "IMG='{{ lca_image }}' make deploy"
      args:
        chdir: "{{ lca_repo }}"
      environment:
        KUBECONFIG: "{{ kubeconfig_file }}"

    - name: Wait for operator to be ready
      ansible.builtin.command:
        cmd: "oc --kubeconfig {{ kubeconfig_file }} wait -n openshift-lifecycle-agent deployment/lifecycle-agent-controller-manager --for=condition=Available --timeout=10m"
      register: operator_ready

    - name: Fail if operator is not ready
      ansible.builtin.fail:
        msg: "Operator is not ready"
      when: operator_ready.rc != 0
PLAYBOOK

ansible-playbook -i "${ANSIBLE_INVENTORY}" deploy-lca.yaml