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
  # secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"

  # if [ -n "${SOCKS5_PROXY}" ]; then
  #   _curl="curl -x ${SOCKS5_PROXY}"
  # else
  #   _curl="curl"
  # fi
}

function install_test_tools {

  set -x
  pip3 install --no-cache-dir "pytest==8.2.2" "pytest-shell==0.3.2" "requests[socks]==2.32.3"
  set +x
}

##############################################################################################################
# Test results
##############################################################################################################

function run_pytest {
  test_name=$1
  test_results_xml_output=${ARTIFACT_DIR}/junit_${test_name}-test-results.xml
  python3 -m pytest ${PYTEST_VERBOSITY} ${tc_file} --junitxml=${test_results_xml_output}
}

function test_deployment_and_services {

  echo "************ telcov10n-spoke Generate Test results ************"

  cat <<EOF-INIT > /tmp/pytest.ini
[pytest]
junit_suite_name = telco-verification
EOF-INIT

cat <<EOF-CONFTEST > /tmp/conftest.py
import pytest

def pytest_collection_modifyitems(items):
    for item in items:
        parts = item.nodeid.split("::")
        if len(parts) > 1:
            test_name = ' '.join(parts[-1].split('_')[1:])
            file_path = parts[0]
            item._nodeid = f"{file_path}::[sig-telco-verification] {test_name.capitalize()}"
EOF-CONFTEST

  tc_file="/tmp/${JOB_NAME_SAFE}.py"
  cat << EOF-PYTEST >| ${tc_file}
import os
import time
import requests
import pytest

def test_spoke_cluster_operators_are_ready(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc get co --no-headers | grep -v 'True .* False .* False' | wc -l"
      if bash.run_script_inline([oc_cmd]) == '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"Not all cluster operators are ready yet"

def test_ptp_operator_has_been_deployed(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc -n openshift-ptp get po --no-headers | grep 'ptp-operator.*Running'"
      if bash.run_script_inline([oc_cmd]) != '':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"PTP operator is not ready yet"

def test_ptp_linuxdaemon_pod_is_running(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc -n openshift-ptp get po --no-headers | grep 'linuxptp-daemon.*Running'"
      if bash.run_script_inline([oc_cmd]) != '':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"PTP operator is not ready yet"

def test_sriov_operator_has_been_deployed(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc -n openshift-sriov-network-operator get po --no-headers | grep 'sriov-network-operator.*Running'"
      if bash.run_script_inline([oc_cmd]) != '':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"SRIOV operator is not ready"

def test_sriovnetwork_cr_has_been_deployed(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc -n openshift-sriov-network-operator get SriovNetwork --no-headers | wc -l"
      if bash.run_script_inline([oc_cmd]) != '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"SriovNetwork CR is not ready"

def test_performace_profile_exists(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc get performanceprofile --no-headers | wc -l"
      if bash.run_script_inline([oc_cmd]) != '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"Performace Profile CR does not exist"

def test_spoke_cluster_deployed_successfully(bash):
    assert True
EOF-PYTEST

  echo
  echo -----------------
  echo $tc_file
  echo -----------------
  cat $tc_file
  echo -----------------
  echo
  run_pytest check_spoke_installation
  echo
}

function test_run_a_pod_in_the_spoke_cluster {

  echo "************ telcov10n Run a POD into Spoke cluster ************"

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

set -x
date -u
uname -a
ls -l
EOF

  spoke_cluster_project="default"
  run_script_on_ocp_cluster ${run_script} ${spoke_cluster_project} "${NAMESPACE}-test-helper" "done"
}

function test_spoke_deployment {

  echo "************ telcov10n Check Spoke Cluster ************"

  # Add here all the verifications needed.
  # The following lines are just a naive example that check web console and
  # run a script inside a POD in the Spoke cluster

  test_deployment_and_services
  test_run_a_pod_in_the_spoke_cluster

  echo
  echo "Success!!! spoke_cluster has been deployed correctly."
  echo "-----------------------------------------------------"
  oc get clusterversion
  echo
}

function copy_spoke_kubeconfig_to_bastion_location {

  echo "************ telcov10n Store SPOKE KUBECONFIG file at Bastion location ************"

  local ssh_key
  ssh_key="$(mktemp)"
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key > ${ssh_key}
  chmod 600 ${ssh_key}
  setup_aux_host_ssh_access "${ssh_key}"

  local spoke_kubeconfig
  spoke_kubeconfig="/tmp/spoke-kubeconfig"
  cat ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml >| ${spoke_kubeconfig}
  chmod +r ${spoke_kubeconfig}
  set -x
  rsync -avP -e "ssh $(echo "${SSHOPTS[@]}")" "${spoke_kubeconfig}" "root@${AUX_HOST}:${AUX_HOST_REMOTE_PATH}/$(basename ${spoke_kubeconfig})"
  set +x
  echo

}

function test_kpis {

  echo "************ telcov10n Run KPIs tests ************"

  # TODO: Run all KPIs testing from this point onward

  copy_spoke_kubeconfig_to_bastion_location

  echo
  echo "Running KPIs tests..."
  echo

}

function main {
  set_spoke_cluster_kubeconfig
  install_test_tools
  test_spoke_deployment
  test_kpis
}

main
