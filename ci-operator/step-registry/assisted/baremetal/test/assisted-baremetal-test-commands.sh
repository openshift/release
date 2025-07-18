#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted baremetal test command ************"

if [ "${TEST_TYPE:-list}" == "none" ]; then
    echo "TEST_TYPE is 'none', skipping test execution."
    exit 0
fi

ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
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

echo "--- Running with the following parameters ---"
echo "TEST_TYPE: ${TEST_TYPE}"
echo "TEST_SUITE: ${TEST_SUITE}"
echo "CUSTOM_TEST_LIST: ${CUSTOM_TEST_LIST:-not set}"
echo "EXTENSIVE_TEST_LIST: ${EXTENSIVE_TEST_LIST:-not set}"
echo "MINIMAL_TEST_LIST: ${MINIMAL_TEST_LIST:-not set}"
echo "TEST_PROVIDER: ${TEST_PROVIDER}"
echo "TEST_SKIPS: ${TEST_SKIPS:-not set}"
echo "-------------------------------------------"

PLAYBOOK_DIR="build/ansible"
mkdir -p "${PLAYBOOK_DIR}"
cd "${PLAYBOOK_DIR}"

MAIN_PLAYBOOK="multi-conf-test.yml"
SINGLE_TEST_TASKS="_run_single_test.yml"

cat > "${MAIN_PLAYBOOK}" <<-EOF
- name: Run OpenShift conformance tests across all clusters
  hosts: primary
  gather_facts: yes
  vars:
    test_type:               "{{ lookup('env','TEST_TYPE')           | default('minimal') }}"
    test_suite:              "{{ lookup('env','TEST_SUITE')          | default('openshift/conformance/parallel') }}"
    custom_test_list:        "{{ lookup('env','CUSTOM_TEST_LIST')    | default('') }}"
    minimal_test_list:       "{{ lookup('env','MINIMAL_TEST_LIST')   | default('') }}"
    extensive_test_list:     "{{ lookup('env','EXTENSIVE_TEST_LIST') | default('') }}"
    test_provider:           "{{ lookup('env','TEST_PROVIDER')       | default('baremetal') }}"
    test_skips:              "{{ lookup('env','TEST_SKIPS')          | default('') }}"
    local_artifact_dir:      "{{ lookup('env','ARTIFACT_DIR')        | default('') }}"
    remote_artifact_base_dir: "/tmp/artifacts"
    test_list_file:          "/tmp/test-list"
    test_skips_file:         "/tmp/test-skips"
    filtered_list_file:      "/tmp/test-list-filtered"
    pull_secret_file:        "/root/pull-secret"

  tasks:
    - name: Find all kubeconfig files
      ansible.builtin.find:
        paths: "{{ ansible_env.KUBECONFIG }}"
        file_type: file
      register: kubeconfigs

    - name: Fail if no kubeconfig files are found
      ansible.builtin.fail:
        msg: "No kubeconfig files found under {{ ansible_env.KUBECONFIG }}"
      when: kubeconfigs.matched == 0

    - name: Run full test process for each kubeconfig found
      ansible.builtin.include_tasks: ${SINGLE_TEST_TASKS}
      loop: "{{ kubeconfigs.files }}"
      loop_control:
        loop_var: kubeconfig_item
EOF

cat > "${SINGLE_TEST_TASKS}" <<-EOF
---
- name: Process kubeconfig {{ kubeconfig_item.path | basename }}
  block:
    - name: Set iteration-specific variables for {{ kubeconfig_item.path | basename }}
      ansible.builtin.set_fact:
        kubeconfig_file: "{{ kubeconfig_item.path }}"
        kubeconfig_basename: "{{ kubeconfig_item.path | basename }}"
        remote_artifact_dir_run: "{{ remote_artifact_base_dir }}/{{ kubeconfig_item.path | basename }}"

    - name: Test run for {{ kubeconfig_basename }}
      block:
        - name: "Lookup conformance-tests image from cluster {{ kubeconfig_basename }}"
          ansible.builtin.command:
            cmd: >
              oc --kubeconfig {{ kubeconfig_file }}
                 adm release info --image-for=tests
          register: tests_image
          changed_when: false

        - name: "Set tests image fact"
          ansible.builtin.set_fact:
            openshift_tests_image: "{{ tests_image.stdout }}"

        - name: "Pull tests image using pull-secret"
          ansible.builtin.command:
            cmd: >
              podman pull --authfile {{ pull_secret_file }} {{ openshift_tests_image }}
          register: pulled_image
          changed_when: false

        - name: "Prepare static test-list (unless suite)"
          when: test_type != 'suite'
          ansible.builtin.copy:
            dest: "{{ test_list_file }}"
            content: >-
              {%- if test_type == 'minimal' -%}
              {{ minimal_test_list }}
              {%- elif test_type == 'extensive' -%}
              {{ extensive_test_list }}
              {%- else -%}
              {{ custom_test_list }}
              {%- endif -%}

        - name: "Fail if custom tests requested but no list provided"
          when: test_type == 'custom' and custom_test_list == ''
          ansible.builtin.fail:
            msg: "CUSTOM_TEST_LIST must be set when TEST_TYPE=custom"

        - name: "Generate suite list via dry-run"
          when: test_type == 'suite'
          ansible.builtin.command:
            cmd: >
              podman run --network host --rm -i
                --authfile {{ pull_secret_file }}
                -e KUBECONFIG={{ kubeconfig_file }}
                -v {{ kubeconfig_file }}:{{ kubeconfig_file }}
                {{ openshift_tests_image }}
                openshift-tests run {{ test_suite }}
                --dry-run
                --provider "{\"type\":\"{{ test_provider }}\"}"
          register: suite_list

        - name: "Write suite list to test-list"
          when: test_type == 'suite'
          ansible.builtin.copy:
            dest: "{{ test_list_file }}"
            content: "{{ suite_list.stdout }}"

        - name: "Write test-skips file"
          ansible.builtin.copy:
            dest: "{{ test_skips_file }}"
            content: "{{ test_skips }}"

        - name: "Filter out skipped tests"
          ansible.builtin.command:
            cmd: >
              grep -v -F -f {{ test_skips_file }} {{ test_list_file }}
          register: filtered
          changed_when: false

        - name: "Write filtered test list"
          ansible.builtin.copy:
            dest: "{{ filtered_list_file }}"
            content: "{{ filtered.stdout }}"

        - name: "Ensure remote artifact dir exists for this run"
          ansible.builtin.file:
            path: "{{ remote_artifact_dir_run }}"
            state: directory
            mode: '0755'

        - name: "Launch conformance tests for {{ kubeconfig_basename }}"
          ansible.builtin.shell: |
            podman run --network host --rm -i \
              --authfile {{ pull_secret_file }} \
              -e KUBECONFIG={{ kubeconfig_file }} \
              -v {{ kubeconfig_file }}:{{ kubeconfig_file }} \
              -v /tmp:/tmp \
              {{ openshift_tests_image }} \
              openshift-tests run \
                -o "{{ remote_artifact_dir_run }}/e2e.log" \
                --junit-dir "{{ remote_artifact_dir_run }}/reports" \
                --file {{ filtered_list_file }}
          register: test_result
          failed_when: >
            (test_result.rc | default(0) | int) != 0 and
            'failed due to a MonitorTest failure' not in (test_result.stderr | default(''))

  always:
    - name: "Collect artifacts for {{ kubeconfig_basename }}"
      block:
        - name: Check if remote artifact directory was created
          ansible.builtin.stat:
            path: "{{ remote_artifact_dir_run }}"
          register: artifact_dir_stat_run

        - name: Proceed with artifact collection if directory exists
          when: artifact_dir_stat_run.stat.exists and artifact_dir_stat_run.stat.isdir
          block:
            - name: Tar up remote artifacts for this run
              ansible.builtin.archive:
                path: "{{ remote_artifact_dir_run }}"
                dest: "/tmp/artifacts_{{ kubeconfig_basename }}.tar.gz"
                format: gz

            - name: Fetch the artifact tarball for this run
              ansible.builtin.fetch:
                src: "/tmp/artifacts_{{ kubeconfig_basename }}.tar.gz"
                dest: "{{ local_artifact_dir }}/"
                flat: yes

            - name: Unpack artifacts locally into a dedicated folder
              delegate_to: localhost
              ansible.builtin.unarchive:
                src: "{{ local_artifact_dir }}/artifacts_{{ kubeconfig_basename }}.tar.gz"
                dest: "{{ local_artifact_dir }}/{{ kubeconfig_basename }}/"
                remote_src: yes
      ignore_errors: yes
EOF

echo "Executing Ansible playbook..."
ansible-playbook "${MAIN_PLAYBOOK}" -i "${ANSIBLE_INVENTORY}"
