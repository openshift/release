#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function setup_socks5_proxy_via_aux_host {

  # The spoke's admin kubeconfig may already have a 'proxy-url: socks5://127.0.0.1:<port>'
  # baked in by the cluster-install step (see add_proxy_to_kubeconfig_if_needed there). That
  # tunnel only lived inside the cluster-install pod, so this pod must open its own tunnel on
  # the same local port for the kubeconfig's proxy-url to find a live listener here too.
  if [ -n "${SOCKS5_PROXY}" ]; then
    echo "************ telcov10n Using the SOCKS5 proxy given by the job config ************"
    return
  fi

  echo "************ telcov10n Open a SOCKS5 tunnel through AUX_HOST ************"

  ssh -f -N -D "127.0.0.1:${SOCKS5_LOCAL_PORT}" \
    -o ExitOnForwardFailure=yes \
    "${SSHOPTS[@]}" "root@${AUX_HOST}"

  for ((attempts = 0 ; attempts < 10 ; attempts++)); do
    if timeout 5 bash -c "> /dev/tcp/127.0.0.1/${SOCKS5_LOCAL_PORT}" 2>/dev/null; then
      export SOCKS5_PROXY="socks5h://127.0.0.1:${SOCKS5_LOCAL_PORT}"
      echo "SOCKS5 tunnel listening on 127.0.0.1:${SOCKS5_LOCAL_PORT}"
      return
    fi
    sleep 3
  done

  echo "[FAIL] The SOCKS5 tunnel through ${AUX_HOST} did not come up..."
  exit 1
}

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  # secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
}

##############################################################################################################
# Test results
##############################################################################################################

function run_pytest {
  test_name=$1
  test_results_xml_output=${ARTIFACT_DIR}/junit_${test_name}-test-results.xml
  pytest ${PYTEST_VERBOSITY} ${tc_file} --junitxml=${test_results_xml_output}
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
    attempts = 15
    while attempts > 0:
      oc_cmd = f"oc get co --no-headers | grep -v 'True .* False .* False' | wc -l"
      if bash.run_script_inline([oc_cmd]) == '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"Not all cluster operators are ready yet"

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
  run_script_on_ocp_cluster ${run_script} ${spoke_cluster_project} "spoke-cluster-pod-helper" "done"
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
}

function main {
  setup_aux_host_ssh_access
  setup_socks5_proxy_via_aux_host
  set_spoke_cluster_kubeconfig
  test_spoke_deployment
}

main
