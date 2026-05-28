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
echo "ARTIFACT_DIR: ${ARTIFACT_DIR:-not set}"
echo "-------------------------------------------"

if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    echo "WARNING: ARTIFACT_DIR is not set; debug files will only be printed to stdout." >&2
else
    mkdir -p "${ARTIFACT_DIR}"
    echo "Ensured ARTIFACT_DIR exists: ${ARTIFACT_DIR}"
fi

PLAYBOOK_DIR="build/ansible"
mkdir -p "${PLAYBOOK_DIR}"
cd "${PLAYBOOK_DIR}"

MAIN_PLAYBOOK="multi-conf-test.yml"
SINGLE_TEST_TASKS="_run_single_test.yml"
READINESS_TASKS="_readiness_wait.yml"
DEBUG_TASKS="_debug_collect.yml"
WAIT_SA_SECRETS_SCRIPT="wait-sa-secrets.sh"
COLLECT_OC_DEBUG_SCRIPT="collect-oc-debug.sh"
COLLECT_NODE_JOURNALS_SCRIPT="collect-node-journals.sh"

cat > "${WAIT_SA_SECRETS_SCRIPT}" <<'SCRIPT'
#!/usr/bin/bash
set -euo pipefail
probe_ns="e2e-readiness-probe-${RANDOM}"
oc create namespace "${probe_ns}"
trap 'oc delete namespace "${probe_ns}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true' EXIT
for attempt in $(seq 1 60); do
  secrets=$(oc get sa default -n "${probe_ns}" -o jsonpath='{.secrets[*].name}' 2>/dev/null || true)
  pull_secrets=$(oc get sa default -n "${probe_ns}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)
  if echo "${secrets} ${pull_secrets}" | tr ' ' '\n' | grep -qE 'dockercfg|dockerconfig'; then
    echo "default service account has image pull secrets after ${attempt} attempt(s): secrets='${secrets}' imagePullSecrets='${pull_secrets}'"
    exit 0
  fi
  echo "attempt ${attempt}/60: waiting for default service account secrets (secrets='${secrets}' imagePullSecrets='${pull_secrets}')"
  sleep 5
done
echo "timed out waiting for default service account dockercfg/dockerconfig secrets in ${probe_ns}" >&2
oc get sa default -n "${probe_ns}" -o yaml || true
exit 1
SCRIPT

cat > "${COLLECT_OC_DEBUG_SCRIPT}" <<'SCRIPT'
#!/usr/bin/bash
set -uo pipefail
debug_base="/tmp/artifacts/debug/${ASSISTED_KUBECONFIG_BASENAME}"
mkdir -p "${debug_base}/node-journals"

collect_oc() {
  local outfile="$1"
  shift
  {
    echo "=== $* ==="
    "$@" || echo "command failed: $* (rc=$?)"
  } >>"${outfile}" 2>&1
}

oc_report="${debug_base}/oc-readiness.txt"
: >"${oc_report}"
collect_oc "${oc_report}" oc get co -o wide
collect_oc "${oc_report}" oc get clusteroperator image-registry -o yaml
collect_oc "${oc_report}" oc get pods -n openshift-image-registry -o wide
collect_oc "${oc_report}" oc get deployment -n openshift-image-registry -o wide
collect_oc "${oc_report}" oc get events -n openshift-image-registry --sort-by=.lastTimestamp
collect_oc "${oc_report}" oc get nodes -o wide
collect_oc "${oc_report}" oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
echo "===== oc-readiness.txt ====="
cat "${oc_report}" || true
SCRIPT

cat > "${COLLECT_NODE_JOURNALS_SCRIPT}" <<'SCRIPT'
#!/usr/bin/bash
set -uo pipefail
debug_base="/tmp/artifacts/debug/${ASSISTED_KUBECONFIG_BASENAME}"
journal_dir="${debug_base}/node-journals"
mkdir -p "${journal_dir}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR)
if [[ -f /root/.ssh/id_rsa ]]; then
  ssh_opts+=(-i /root/.ssh/id_rsa)
fi

virsh list --name > "${journal_dir}/virsh-list.txt" 2>&1 || true
while IFS= read -r vm_name; do
  [[ -z "${vm_name}" ]] && continue
  domifaddr_file="${journal_dir}/${vm_name}.domifaddr.txt"
  virsh domifaddr "${vm_name}" > "${domifaddr_file}" 2>&1 || true
  vm_ip=""
  vm_ip6=""
  while read -r _ifname _mac _proto _addr _rest; do
    [[ -n "${_addr}" ]] || continue
    case "${_proto}" in
      ipv4)
        [[ -z "${vm_ip}" ]] && vm_ip="${_addr%%/*}"
        ;;
      ipv6)
        [[ -z "${vm_ip6}" ]] && vm_ip6="${_addr%%/*}"
        ;;
    esac
  done < "${domifaddr_file}"
  # One interface is enough; prefer IPv4 for simpler SSH.
  vm_ip="${vm_ip:-${vm_ip6}}"
  if [[ -z "${vm_ip}" ]]; then
    echo "no IPv4/IPv6 address found for VM ${vm_name}" | tee "${journal_dir}/${vm_name}.no-ip.log"
    continue
  fi
  if [[ "${vm_ip}" == *:* ]]; then
    ssh_target="core@[${vm_ip}]"
    safe_ip="${vm_ip//:/-}"
  else
    ssh_target="core@${vm_ip}"
    safe_ip="${vm_ip//./-}"
  fi
  journal_file="${journal_dir}/${vm_name}-${safe_ip}.journal.log"
  echo "collecting journal for VM ${vm_name} at ${vm_ip}"
  # -n: do not read stdin (otherwise ssh consumes the VM list still being read)
  if ssh -n "${ssh_opts[@]}" "${ssh_target}" journalctl --no-pager > "${journal_file}" 2>&1; then
    echo "journal collection succeeded for ${vm_name}@${vm_ip}"
  else
    echo "journal collection failed for ${vm_name}@${vm_ip}" > "${journal_file}"
  fi
  echo "===== journal ${vm_name} ${vm_ip} ====="
  cat "${journal_file}" || true
done < <(grep -v '^[[:space:]]*$' "${journal_dir}/virsh-list.txt" 2>/dev/null || true)
SCRIPT

chmod +x "${WAIT_SA_SECRETS_SCRIPT}" "${COLLECT_OC_DEBUG_SCRIPT}" "${COLLECT_NODE_JOURNALS_SCRIPT}"

cat > "${MAIN_PLAYBOOK}" <<-EOF
- name: Run OpenShift conformance tests across all clusters
  hosts: primary
  gather_facts: yes
  vars:
    test_type:               "{{ lookup('env','TEST_TYPE')           | default('none') }}"
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
    raw_test_list_file:      "/tmp/test-list-raw"
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

        - name: "Prepare static test-list for extensive and custom"
          when: test_type == 'extensive' or test_type == 'custom'
          ansible.builtin.copy:
            dest: "{{ test_list_file }}"
            content: >-
              {%- if test_type == 'extensive' -%}
              {{ extensive_test_list }}
              {%- else -%}
              {{ custom_test_list }}
              {%- endif -%}

        - name: "Fail if custom tests requested but no list provided"
          when: test_type == 'custom' and custom_test_list == ''
          ansible.builtin.fail:
            msg: "CUSTOM_TEST_LIST must be set when TEST_TYPE=custom"

        - name: "Determine test suite for dynamic discovery"
          when: test_type == 'suite' or test_type == 'minimal'
          ansible.builtin.set_fact:
            effective_test_suite: >-
              {%- if test_type == 'minimal' -%}
              openshift/conformance/parallel
              {%- else -%}
              {{ test_suite }}
              {%- endif -%}

        - name: "Set filter for minimal test suite"
          when: test_type == 'minimal'
          ansible.builtin.set_fact:
            minimal_test_filter: >-
              {%- if test_type == 'minimal' -%}
              --run minimal
              {%- else -%}
              ""
              {%- endif -%}

        - name: "Generate suite list via dry-run"
          when: test_type == 'suite' or test_type == 'minimal'
          ansible.builtin.command:
            cmd: >
              podman run --network host --rm -i
                --authfile {{ pull_secret_file }}
                -e KUBECONFIG={{ kubeconfig_file }}
                -v {{ kubeconfig_file }}:{{ kubeconfig_file }}
                {{ openshift_tests_image }}
                openshift-tests run {{ effective_test_suite }}
                --dry-run
                {{ minimal_test_filter }}
                --provider "{\"type\":\"{{ test_provider }}\"}"
          register: suite_list

        - name: "Write suite list to test-list"
          when: test_type == 'suite' or test_type == 'minimal'
          ansible.builtin.copy:
            dest: "{{ raw_test_list_file }}"
            content: "{{ suite_list.stdout }}"

        - name: "Get the test list from the raw output"
          when: test_type == 'suite' or test_type == 'minimal'
          ansible.builtin.command:
            cmd: >
              grep '^"\\[' "{{ raw_test_list_file }}"
          register: test_list
          changed_when: false

        - name: "Write test list to test-list file"
          when: test_type == 'suite' or test_type == 'minimal'
          ansible.builtin.copy:
            dest: "{{ test_list_file }}"
            content: "{{ test_list.stdout }}"

        - name: "Write test-skips file"
          ansible.builtin.copy:
            dest: "{{ test_skips_file }}"
            content: "{{ test_skips }}"

        - name: Wait for cluster readiness before conformance tests
          block:
            - name: Include readiness wait tasks
              ansible.builtin.include_tasks: ${READINESS_TASKS}
          ignore_errors: true

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

        - name: "Print conformance tests to be run for {{ kubeconfig_basename }}"
          ansible.builtin.debug:
            msg:
              - "test count={{ filtered.stdout_lines | length }}"
              - "{{ filtered.stdout_lines }}"

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
                --provider "{\"type\":\"{{ test_provider }}\"}" \
                --file {{ filtered_list_file }}
          register: test_result
          failed_when: >
            (test_result.rc | default(0) | int) != 0 and
            'failed due to a MonitorTest failure' not in (test_result.stderr | default(''))

      always:
        - name: Collect OpenShift and node debug information after test failure
          when: >
            test_result is defined and
            (test_result.rc | default(0) | int) != 0
          block:
            - name: Include debug collection tasks
              ansible.builtin.include_tasks: ${DEBUG_TASKS}
          ignore_errors: true

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
              when: local_artifact_dir | length > 0

            - name: Ensure local artifact unpack directory exists
              delegate_to: localhost
              ansible.builtin.file:
                path: "{{ local_artifact_dir }}/{{ kubeconfig_basename }}"
                state: directory
                mode: '0755'
              when: local_artifact_dir | length > 0

            - name: Unpack artifacts locally into a dedicated folder
              delegate_to: localhost
              ansible.builtin.unarchive:
                src: "{{ local_artifact_dir }}/artifacts_{{ kubeconfig_basename }}.tar.gz"
                dest: "{{ local_artifact_dir }}/{{ kubeconfig_basename }}/"
                remote_src: yes
              when: local_artifact_dir | length > 0
      ignore_errors: yes
EOF

cat > "${READINESS_TASKS}" <<-EOF
---
- name: Wait for all clusteroperators to be Available
  ansible.builtin.command:
    cmd: >
      oc --kubeconfig {{ kubeconfig_file }}
      wait clusteroperators --all
      --for=condition=Available=True --timeout=10m
  register: readiness_wait_co
  changed_when: false

- name: Wait for image-registry clusteroperator to be Available
  ansible.builtin.command:
    cmd: >
      oc --kubeconfig {{ kubeconfig_file }}
      wait clusteroperator/image-registry
      --for=condition=Available=True --timeout=10m
  register: readiness_wait_image_registry_co
  changed_when: false

- name: Wait for image-registry pods to be Ready
  ansible.builtin.command:
    cmd: >
      oc --kubeconfig {{ kubeconfig_file }}
      wait -n openshift-image-registry
      --for=condition=Ready pod --all --timeout=10m
  register: readiness_wait_image_registry_pods
  changed_when: false

- name: Wait for image-registry deployment to exist
  ansible.builtin.command:
    cmd: >
      oc --kubeconfig {{ kubeconfig_file }}
      get deployment -n openshift-image-registry
  register: readiness_image_registry_deployments
  changed_when: false
  retries: 30
  delay: 10
  until: readiness_image_registry_deployments.rc == 0

- name: Probe namespace for default service account image pull secrets
  ansible.builtin.script: ${WAIT_SA_SECRETS_SCRIPT}
  environment:
    KUBECONFIG: "{{ kubeconfig_file }}"
  register: readiness_wait_sa_secrets
  changed_when: false

- name: Print readiness wait summary
  ansible.builtin.debug:
    msg:
      - "clusteroperators: {{ readiness_wait_co.rc | default('skipped') }}"
      - "image-registry CO: {{ readiness_wait_image_registry_co.rc | default('skipped') }}"
      - "image-registry pods: {{ readiness_wait_image_registry_pods.rc | default('skipped') }}"
      - "image-registry deployments: {{ readiness_image_registry_deployments.rc | default('skipped') }}"
      - "probe SA secrets: {{ readiness_wait_sa_secrets.rc | default('skipped') }}"
EOF

cat > "${DEBUG_TASKS}" <<-EOF
---
- name: Report ARTIFACT_DIR on the test runner
  delegate_to: localhost
  ansible.builtin.debug:
    msg: >-
      ARTIFACT_DIR env={{ lookup('env', 'ARTIFACT_DIR') | default('<not set>', true) }};
      local_artifact_dir={{ local_artifact_dir | default('<not set>', true) }}

- name: Ensure local debug artifact directories exist on the test runner
  delegate_to: localhost
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - "{{ local_artifact_dir }}/debug"
    - "{{ local_artifact_dir }}/debug/{{ kubeconfig_basename }}"
  when: local_artifact_dir | length > 0

- name: Collect OpenShift cluster readiness debug state
  ansible.builtin.script: ${COLLECT_OC_DEBUG_SCRIPT}
  environment:
    KUBECONFIG: "{{ kubeconfig_file }}"
    ASSISTED_KUBECONFIG_BASENAME: "{{ kubeconfig_basename }}"
  register: oc_debug_collect
  changed_when: false
  ignore_errors: true

- name: Collect journal logs from libvirt VMs via domifaddr
  ansible.builtin.script: ${COLLECT_NODE_JOURNALS_SCRIPT}
  environment:
    ASSISTED_KUBECONFIG_BASENAME: "{{ kubeconfig_basename }}"
  register: journal_debug_collect
  changed_when: false
  ignore_errors: true

- name: Print OpenShift debug collection output
  ansible.builtin.debug:
    var: oc_debug_collect.stdout_lines
  when: oc_debug_collect.stdout_lines is defined
  ignore_errors: true

- name: Print node journal collection output
  ansible.builtin.debug:
    var: journal_debug_collect.stdout_lines
  when: journal_debug_collect.stdout_lines is defined
  ignore_errors: true

- name: Archive remote debug directory
  ansible.builtin.archive:
    path: "/tmp/artifacts/debug/{{ kubeconfig_basename }}"
    dest: "/tmp/artifacts/debug_{{ kubeconfig_basename }}.tar.gz"
    format: gz
  ignore_errors: true

- name: Fetch debug archive to ARTIFACT_DIR on the test runner
  ansible.builtin.fetch:
    src: "/tmp/artifacts/debug_{{ kubeconfig_basename }}.tar.gz"
    dest: "{{ local_artifact_dir }}/debug/"
    flat: yes
  when: local_artifact_dir | length > 0
  ignore_errors: true

- name: Unpack debug archive under ARTIFACT_DIR on the test runner
  delegate_to: localhost
  ansible.builtin.unarchive:
    src: "{{ local_artifact_dir }}/debug/debug_{{ kubeconfig_basename }}.tar.gz"
    dest: "{{ local_artifact_dir }}/debug/{{ kubeconfig_basename }}/"
    remote_src: yes
  when: local_artifact_dir | length > 0
  ignore_errors: true
EOF

echo "Executing Ansible playbook..."
ansible-playbook "${MAIN_PLAYBOOK}" -i "${ANSIBLE_INVENTORY}"
