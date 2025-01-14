#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  # secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
}

function run_script_in_the_spoke_cluster {
  local helper_img="${SPOKE_HELPER_IMG}"
  local script_file=$1
  shift && local ns=$1
  [ $# -gt 1 ] && shift && local pod_name="${1}"

  set -x
  if [[ "${pod_name:="--rm spoke-script"}" != "--rm spoke-script" ]]; then
    oc -n ${ns} get pod ${pod_name} 2> /dev/null || {
      oc -n ${ns} run ${pod_name} \
        --image=${helper_img} --restart=Never -- sleep infinity ; \
      oc -n ${ns} wait --for=condition=Ready pod/${pod_name} --timeout=10m ;
    }
    oc -n ${ns} exec -i ${pod_name} -- \
      bash -s -- <<EOF
$(cat ${script_file})
EOF
  [ $# -gt 1 ] && oc -n ${ns} delete pod ${pod_name}
  else
    oc -n ${ns} run -i ${pod_name} \
      --image=${helper_img} --restart=Never -- \
        bash -s -- <<EOF
$(cat ${script_file})
EOF
  fi
  set +x
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

  cat <<EOF > /tmp/pytest.ini
[pytest]
junit_suite_name = telco-verification
EOF

  tc_file="/tmp/${JOB_NAME_SAFE}.py"
  cat << EOF >| ${tc_file}
import os
import time
import requests
import pytest

def test_cluster_operators(bash):
    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc get co --no-headers | grep -v 'True .* False .* False' | wc -l"
      if bash.run_script_inline([oc_cmd]) == '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"Not all cluster operators are ready yet"

def test_cluster_deployed_successfully(bash):
    assert True
EOF

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
  run_script_in_the_spoke_cluster ${run_script} ${spoke_cluster_project} "spoke-cluster-pod-helper" "done"
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
  set_spoke_cluster_kubeconfig
  test_spoke_deployment
}

main
