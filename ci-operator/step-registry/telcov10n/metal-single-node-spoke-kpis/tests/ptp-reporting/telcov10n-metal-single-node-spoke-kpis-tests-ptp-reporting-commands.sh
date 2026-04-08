#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig

  export KUBECONFIG="/tmp/spoke-${secret_kubeconfig}.yaml"
  cat ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml >| ${KUBECONFIG}
  chmod 0644 ${KUBECONFIG}
}

function load_env {

  #### Remote Bastion jump host
  export BASTION_HOST=${AUX_HOST}

  #### SSH Private key
  export BASTION_HOST_SSH_PRI_KEY_FILE="/tmp/remote-hypervisor-ssh-privkey"
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key >| ${BASTION_HOST_SSH_PRI_KEY_FILE}
  chmod 600 ${BASTION_HOST_SSH_PRI_KEY_FILE}

  #### Bastion user
  BASTION_HOST_USER="$(cat /var/run/telcov10n/ansible-group-all/ansible_user)"
  export BASTION_HOST_USER
}

function make_up_inventory {

  load_env

inventory_file="/tmp/bastion-node-inventory.yml"
  cat <<EO-inventory >| $inventory_file
all:
  children:
    prow_bastion:
      hosts:
        bastion-node:
          ansible_host: "{{ lookup('ansible.builtin.env', 'BASTION_HOST') }}"
          ansible_user: "{{ lookup('ansible.builtin.env', 'BASTION_HOST_USER') }}"
          ansible_ssh_private_key_file: "{{ lookup('ansible.builtin.env', 'BASTION_HOST_SSH_PRI_KEY_FILE') }}"
          ansible_ssh_common_args: ' \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ServerAliveInterval=90 \
            -o LogLevel=ERROR'
EO-inventory

}

function make_up_remote_test_command {

  run_command=/tmp/run_command.sh

  cat <<EOF >| ${run_command}
#!/bin/bash

# Test ENV setup (same pattern as OSLAT/CPU-util)
mkdir -pv \${HOME}/.local/bin
export PATH=\$PATH:\${HOME}/.local/bin
export RAN_METRICS_URL="${TELCO_KPI_RAN_METRICS_END_POINT_URL}"
echo "insecure" >| \${HOME}/.curlrc

set -x
kpi_tests_repo=\$(dirname \${SCRIPTS_DIR})
export GIT_SSL_NO_VERIFY=true
git clone ${TELCO_KPI_COMMON_REPO} \${kpi_tests_repo}
cd \${kpi_tests_repo}
set +x
ls -rtlhZ
pwd
set -x

# Run test_ptp.sh from ran-integration (follows OSLAT pattern)
# Format: ptp=\${DURATION} (e.g., ptp=1m)
bash \${SCRIPTS_DIR}/test_ptp.sh ptp=\${DURATION}
set +x
EOF

  chmod +x ${run_command}
}

function make_up_ansible_playbook {
  ansible_playbook="/tmp/ansible_playbook_for_telco_kpi_tests.yml"

  test_results_artifacts_append=${SHARED_DIR}/telco_${TELCO_KPI_TEST_NAME// /-}_kpi_results

  cat << EO-playbook >| ${ansible_playbook}
---
- name: Telco KPI PTP Reporting tests playbook
  hosts:
    - all
  gather_facts: false

  tasks:

  - name: Setup a Podman container to run ${TELCO_KPI_TEST_NAME} Telco KPI test
    vars:
      _helper_image_tag: "telco-kpi-tests-helper-${TELCO_KPI_TEST_NAME// /-}"
      _kubeconfig: "${KUBECONFIG}"
      _run_cmd: "${run_command}"
      _test_results_artifacts_append: "${test_results_artifacts_append}"

    block:

      - name: Create temporary remote dir
        ansible.builtin.tempfile:
          state: directory
          prefix: "telco-kpi-${TELCO_KPI_TEST_NAME// /-}-test-"
        register: _telco_kpis

      - name: Set vars and paths relative to temporary dir
        ansible.builtin.set_fact:
          _remote_kubeconfig: "{{ _telco_kpis.path }}/{{ _kubeconfig | basename }}"
          _remote_run_cmd: "{{ _telco_kpis.path }}/{{ _run_cmd | basename }}"
          _remote_container_file: "{{ _telco_kpis.path }}/Containerfile"
          _remote_telco_ran_integration_repo: "{{ _telco_kpis.path }}/ran-integration"
          _remote_telco_ran_integration_tests_results: "{{ _telco_kpis.path }}/ran-integration/artifacts"

      - name: Copy artifacts to bastion host
        ansible.builtin.copy:
          src: "{{ item.src }}"
          dest: "{{ item.dest }}"
          mode: "{{ item.mode }}"
        loop:
          - src: "{{ _kubeconfig }}"
            dest: "{{ _remote_kubeconfig }}"
            mode: "0666"
          - src: "{{ _run_cmd }}"
            dest: "{{ _remote_run_cmd }}"
            mode: "0755"

      - name: Building Podman container image at bastion host
        vars:
          _base_img: quay.io/centos/centos:stream9
          _oc_bin_url: https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.18/openshift-client-linux.tar.gz
        ansible.builtin.shell: |
          cat << EO-Containerfile > {{ _remote_container_file }}
          FROM quay.io/centos/centos:stream9
          RUN dnf -y install binutils diffutils skopeo git python3 python3-pip python3-devel jq bc && \
            dnf clean all && \
            curl -sSLO {{ _oc_bin_url }} && \
            tar -zxvf {{ _oc_bin_url | basename }} && \
            mv oc /usr/local/bin/ && \
            mv kubectl /usr/local/bin/ && \
            rm -f {{ _oc_bin_url | basename }}
          ENV TELCO_KPI_TEST_NAME="${TELCO_KPI_TEST_NAME}"
          EO-Containerfile

          podman build \
            -t {{ _helper_image_tag }} \
            -f Containerfile \
            {{ _remote_container_file | dirname }}

      - name: Running the ${TELCO_KPI_TEST_NAME} test
        ansible.builtin.shell: |
          mkdir -pv {{ _remote_telco_ran_integration_repo }}
          podman run --rm -ti \
              \
              -e KUBECONFIG={{ _remote_kubeconfig }} \
              -e SCRIPTS_DIR="{{ _remote_telco_ran_integration_repo }}/scripts" \
              -e DURATION="${TELCO_KPI_TEST_DURATION}" \
              \
              -v {{ _remote_kubeconfig }}:{{ _remote_kubeconfig }}:Z \
              -v {{ _remote_telco_ran_integration_repo }}:{{ _remote_telco_ran_integration_repo }}:Z \
              -v {{ _remote_run_cmd }}:{{ _remote_run_cmd }}:Z \
              \
              {{ _helper_image_tag }} bash {{ _remote_run_cmd }}

      - name: Gather ${TELCO_KPI_TEST_NAME} tests logs and results
        ansible.builtin.shell: |
          find {{ _remote_telco_ran_integration_tests_results }} -maxdepth 1 -type f
        register: _telco_kpi_artifacts

      - name: Fetch results and store them into SHARED folder
        ansible.builtin.fetch:
          src: "{{ item }}"
          dest: "{{ _test_results_artifacts_append }}_{{ item | basename }}"
          flat: true
        loop: "{{ _telco_kpi_artifacts.stdout_lines }}"

    always:

      - name: Remove the remote temporary dir
        when: _telco_kpis.path is defined
        ansible.builtin.file:
          path: "{{ _telco_kpis.path }}"
          state: absent
EO-playbook

  echo
  echo "----------------------------------------"
  ls -l ${ansible_playbook}
  echo "----------------------------------------"
  cat ${ansible_playbook}
  echo "----------------------------------------"
  echo
}

function run_ansible_playbook {

  echo
  echo "Running KPIs tests..."
  echo

  set -x
  oc get no,clusterversion -owide
  set +x

  ansible-playbook -i ${inventory_file} ${ansible_playbook} -vvv
}

function setup_test_result_for_component_readiness {

  echo "************ Copying artifacts to ARTIFACT_DIR ************"

  test_results_artifacts_append=${SHARED_DIR}/telco_${TELCO_KPI_TEST_NAME// /-}_kpi_results
  local tar_staging_dir
  local tar_archive
  tar_staging_dir=$(mktemp -d)
  tar_archive="${ARTIFACT_DIR}/ptp_${TELCO_KPI_TEST_NAME// /-}_artifacts.tar.gz"

  set -x

  # Copy all artifacts to staging dir with ptp_ prefix
  # They will be bundled into a single tar.gz to stay under 3MB artifact limit
  for artifact in ${test_results_artifacts_append}*; do
    if [ -f "$artifact" ]; then
      basename=$(basename "$artifact")
      cp -v "$artifact" "${tar_staging_dir}/ptp_${basename}"
    fi
  done

  # Create tar.gz archive of all artifacts (gzip is the only compression available in CI image)
  echo "Creating tar.gz archive of PTP artifacts..."
  tar -czvf "${tar_archive}" -C "${tar_staging_dir}" .
  rm -rf "${tar_staging_dir}"

  # Clean up raw artifacts from SHARED_DIR to stay under 3MB secret limit
  # The archived version in ARTIFACT_DIR preserves all data
  echo "Cleaning up raw PTP artifacts from SHARED_DIR (CI secret limit is 3MB)..."
  rm -fv ${test_results_artifacts_append}*.ptplog 2>/dev/null || true

  # Process JUnit XML for CI integration (same as OSLAT/CPU-util)
  # These must remain uncompressed for CI to parse them
  if ls ${test_results_artifacts_append}*.xml 1>/dev/null 2>&1; then
    sed -E \
      -e 's/(<testsuite name=")[^"]+/\1telco-verification/' \
      -e "s/<testcase name=\"([^\"]+)\"/<testcase name='${TEST_COMPONENT} \1'/" \
      ${test_results_artifacts_append}*.xml \
        >| "${ARTIFACT_DIR}/junit_${TELCO_KPI_TEST_NAME// /-}_telco_kpi_test_results.xml"
  else
    echo "WARNING: No XML artifacts found"
  fi

  set +x

  echo "************ Artifacts in ARTIFACT_DIR ************"
  ls -lh "${tar_archive}" ${ARTIFACT_DIR}/junit_${TELCO_KPI_TEST_NAME// /-}* 2>/dev/null || true

  # Show total artifact size (limit is 3MB)
  echo "************ Total artifact size ************"
  du -ch "${tar_archive}" ${ARTIFACT_DIR}/junit_${TELCO_KPI_TEST_NAME// /-}* 2>/dev/null | tail -1 || true

  # Show tar.gz contents
  echo "************ Archive contents ************"
  tar -tzvf "${tar_archive}"

  if [ -f "${ARTIFACT_DIR}/junit_${TELCO_KPI_TEST_NAME// /-}_telco_kpi_test_results.xml" ]; then
    echo "************ JUnit XML content ************"
    cat "${ARTIFACT_DIR}/junit_${TELCO_KPI_TEST_NAME// /-}_telco_kpi_test_results.xml"
  fi
}

function test_kpis {

  echo "************ telcov10n Run PTP Reporting Telco KPIs test ************"

  make_up_inventory
  make_up_remote_test_command
  make_up_ansible_playbook
  run_ansible_playbook
  setup_test_result_for_component_readiness
}

function main {
  set_spoke_cluster_kubeconfig
  test_kpis
}

main
