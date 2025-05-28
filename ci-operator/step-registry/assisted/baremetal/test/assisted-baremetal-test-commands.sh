#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted baremetal test command ************"

if [ "${TEST_TYPE:-list}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

ANSIBLE_CONFIG="${SHARED_DIR}/ansible.cfg"
if [[ ! -f "$ANSIBLE_CONFIG" ]]; then
    echo "${ANSIBLE_CONFIG} not found"
    exit 1
fi
export ANSIBLE_CONFIG

ANSIBLE_INVENTORY="${SHARED_DIR}/inventory"
if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
    echo "${ANSIBLE_INVENTORY} not found"
    exit 1
fi
export ANSIBLE_INVENTORY

echo "TEST_TYPE: ${TEST_TYPE}"
echo "TEST_SUITE: ${TEST_SUITE}"
echo "CUSTOM_TEST_LIST: ${CUSTOM_TEST_LIST}"
echo "EXTENSIVE_TEST_LIST: ${EXTENSIVE_TEST_LIST}"
echo "MINIMAL_TEST_LIST: ${MINIMAL_TEST_LIST}"
echo "TEST_PROVIDER: ${TEST_PROVIDER}"
echo "TEST_SKIPS: ${TEST_SKIPS}"

mkdir -p build/ansible
cd build/ansible

cat > conformance-tests.yaml <<-EOF
- name: Run OpenShift conformance tests
  hosts: all
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
    remote_artifact_dir:     "/tmp/artifacts"
    test_list_file:          "/tmp/test-list"
    test_skips_file:         "/tmp/test-skips"
    filtered_list_file:      "/tmp/test-list-filtered"
    pull_secret_file:        "/root/pull-secret"

  tasks:
    - name: Find kubeconfig files
      ansible.builtin.find:
        paths: "{{ ansible_env.KUBECONFIG }}"
        file_type: file
      register: kubeconfigs

    - name: Fail if there isn't exactly one kubeconfig
      ansible.builtin.fail:
        msg: >
          Expected exactly one kubeconfig under {{ ansible_env.KUBECONFIG }},
          but found {{ kubeconfigs.matched }}
      when: kubeconfigs.matched != 1

    - name: Set the single kubeconfig path
      ansible.builtin.set_fact:
        kubeconfig_file: "{{ kubeconfigs.files[0].path }}"

    - name: Lookup conformance-tests image from the running cluster
      ansible.builtin.command:
        cmd: >
          oc --kubeconfig {{ kubeconfig_file }} \
             adm release info --image-for=tests
      register: tests_image
      changed_when: false

    - name: Set tests image fact
      ansible.builtin.set_fact:
        openshift_tests_image: "{{ tests_image.stdout }}"

    - name: Pull tests image using pull-secret
      ansible.builtin.command:
        cmd: >
          podman pull --authfile {{ pull_secret_file }} {{ openshift_tests_image }}
      register: pulled_image
      changed_when: false

    - name: Prepare static test-list (unless suite)
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

    - name: Fail if custom tests requested but no list provided
      when: test_type == 'custom' and custom_test_list == ''
      ansible.builtin.fail:
        msg: "CUSTOM_TEST_LIST must be set when TEST_TYPE=custom"

    - name: Generate suite list via dry-run
      when: test_type == 'suite'
      ansible.builtin.command:
        cmd: >
          podman run --network host --rm -i
            --authfile {{ pull_secret_file }}
            -e KUBECONFIG={{ ansible_env.KUBECONFIG }}
            -v {{ ansible_env.KUBECONFIG }}:{{ ansible_env.KUBECONFIG }}
            {{ openshift_tests_image }}
            openshift-tests run {{ test_suite }}
            --dry-run
            --provider "{\"type\":\"{{ test_provider }}\"}"
      register: suite_list

    - name: Write suite list to test-list
      when: test_type == 'suite'
      ansible.builtin.copy:
        dest: "{{ test_list_file }}"
        content: "{{ suite_list.stdout }}"

    - name: Write test-skips file
      ansible.builtin.copy:
        dest: "{{ test_skips_file }}"
        content: "{{ test_skips }}"

    - name: Filter out skipped tests
      ansible.builtin.command:
        cmd: >
          grep -v -F -f {{ test_skips_file }} {{ test_list_file }}
      register: filtered
      changed_when: false

    - name: Write filtered test list
      ansible.builtin.copy:
        dest: "{{ filtered_list_file }}"
        content: "{{ filtered.stdout }}"

    - name: Ensure remote artifact dir exists
      ansible.builtin.file:
        path: "{{ remote_artifact_dir }}"
        state: directory
        mode: '0755'

    - name: Run tests & collect artifacts
      block:

        - name: Launch conformance tests (async)
          ansible.builtin.shell: |
            podman run --network host --rm -i \
              --authfile {{ pull_secret_file }} \
              -e KUBECONFIG={{ kubeconfig_file }} \
              -v {{ kubeconfig_file }}:{{ kubeconfig_file }} \
              -v /tmp:/tmp \
              {{ tests_image.stdout }} \
              openshift-tests run \
                -o "{{ remote_artifact_dir }}/e2e_{{ inventory_hostname }}.log" \
                --junit-dir "{{ remote_artifact_dir }}/reports" \
                --file {{ filtered_list_file }}
          async: 7200
          poll: 0
          register: test_job

        - name: Wait for tests to finish (allow MonitorTest failures)
          ansible.builtin.async_status:
            jid: "{{ test_job.ansible_job_id }}"
          register: result
          until: result.finished
          retries: 60
          delay: 60
          failed_when: false

        - name: Fail if tests really errored
          ansible.builtin.fail:
            msg: |
              Conformance tests exited with code {{ result.rc | default('N/A') }}
              stdout={{ result.stdout | default('') }}
              stderr={{ result.stderr | default('') }}
          when: >
            (result.rc | default(0) | int) != 0 and
            'failed due to a MonitorTest failure' not in (result.stderr | default(''))

      rescue:
        - ansible.builtin.debug:
            msg: "Tests failed, but continuing to fetch artifacts..."

      always:
        - name: Tar up remote artifacts
          ansible.builtin.archive:
            path: "{{ remote_artifact_dir }}"
            dest: "/tmp/artifacts.tar.gz"
            format: gz

        - name: Fetch the tarball
          ansible.builtin.fetch:
            src: "/tmp/artifacts.tar.gz"
            dest: "/tmp/artifacts.tar.gz"
            flat: yes

        - name: Unpack artifacts locally (flatten one directory level)
          delegate_to: localhost
          ansible.builtin.unarchive:
            src: "/tmp/artifacts.tar.gz"
            dest: "{{ local_artifact_dir }}/"
            remote_src: yes
            extra_opts:
              - --strip-components=1

EOF

ansible-playbook conformance-tests.yaml -i "${ANSIBLE_INVENTORY}"
