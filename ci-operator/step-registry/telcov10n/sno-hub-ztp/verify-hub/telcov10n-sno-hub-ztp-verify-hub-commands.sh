#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

function append_pr_tag_cluster_profile_artifacts {

  telco_qe_preserved_dir=/var/builds/telco-qe-preserved

  # Just in case of running this script being part of a Pull Request
  if [ -n "${PULL_NUMBER:-}" ]; then
    echo "************ telcov10n Append the 'pr-${PULL_NUMBER}' tag to '${SHARED_HUB_CLUSTER_PROFILE}' folder ************"
    # shellcheck disable=SC2153
    telco_qe_preserved_dir="${telco_qe_preserved_dir}-pr-${PULL_NUMBER}"
  fi
}

function get_hub_cluster_profile_artifacts {

  echo "************ telcov10n Get Hub cluster artifacts from AUX_HOST ************"

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "root@${AUX_HOST}":${telco_qe_preserved_dir}/${SHARED_HUB_CLUSTER_PROFILE}/ \
    ${HOME}/${SHARED_HUB_CLUSTER_PROFILE}
  set +x
  echo
}

function set_hub_cluster_kubeconfig {

  echo "************ telcov10n Set Hub cluster kubeconfig got from shared profile ************"

  hub_kubeconfig="${HOME}/${SHARED_HUB_CLUSTER_PROFILE}/hub-kubeconfig"
  oc_hub="oc --kubeconfig ${hub_kubeconfig}"
}

##############################################################################################################
# Test results
##############################################################################################################

function run_pytest {

  junitxml_dir=${ARTIFACT_DIR}/junit/
  mkdir -pv ${junitxml_dir}

  test_name=$1
  test_results_xml_output=${junitxml_dir}/${test_name}-test-results.xml

  pytest ${PYTEST_VERBOSITY} ${tc_file} --junitxml=${test_results_xml_output}
}

function test_deployment_and_services {

  echo "************ telcov10n-vhub Generate Test results ************"

  tc_file="/tmp/pytest-tc.py"
  cat << EOF >| ${tc_file}
import os
import time
import requests
import pytest

@pytest.mark.parametrize("url", [
    ("$($oc_hub whoami --show-console)", 200),
    ("$($oc_hub get managedcluster local-cluster -ojsonpath='{.spec.managedClusterClientConfigs[0].url}')", 403),
])
def test_http_endpoint(url):
    response = requests.get(url[0], verify=False)
    assert response.status_code == url[1], f"Endpoint {url[0]} is not accessible. Status code: {response.status_code}"

def test_cluster_version(bash):
    oc_cmd = "oc get clusterversion version -ojsonpath='{.status.desired.version}'"
    assert bash.run_script_inline([oc_cmd]).startswith("${OCP_HUB_VERSION}")

@pytest.mark.parametrize("namespace", [
    "${MCH_NAMESPACE}",
    "multicluster-engine",
    "openshift-gitops",
])
def test_ztp_namespaces(bash, namespace):
    oc_cmd = f"oc get ns {namespace} " + "-ojsonpath='{.metadata.name}'"
    assert bash.run_script_inline([oc_cmd]) == namespace

    count = 0
    attempts = 10
    while attempts > 0:
      oc_cmd = f"oc -n {namespace} get po --no-headers | grep -v -E 'Running|Completed' | wc -l"
      if bash.run_script_inline([oc_cmd]) == '0':
        break
      attempts -= 1
      time.sleep(60)
    assert attempts > 0, f"Not all PODs in {namespace} namespace are ready yet"

def test_ztp_storageclass(bash):
    oc_cmd = f"oc get storageclass --no-headers | grep -w '(default)'"
    assert " (default) " in bash.run_script_inline([oc_cmd])
EOF

  run_pytest check_hub_installation
}

function test_hub_cluster_deployment {

  set -x
  diff -u ${KUBECONFIG} ${hub_kubeconfig} || \
    ( echo "Wrong KUBECONFIG file retreived!!! Exiting..." && exit 1 )
  $oc_hub get no,clusterversion,mcp,co,sc,pv
  $oc_hub get subscriptions.operators,OperatorGroup,pvc -A
  $oc_hub whoami --show-console
  $oc_hub get managedcluster
  set +x

  echo "Current namespace is ${NAMESPACE}"
  base_domain=$(cat ${HOME}/${SHARED_HUB_CLUSTER_PROFILE}/base_domain)
  echo "Current base_domain is ${base_domain}"

  test_deployment_and_services

  echo "Exiting successfully..."
}

function main {
  setup_aux_host_ssh_access
  append_pr_tag_cluster_profile_artifacts
  get_hub_cluster_profile_artifacts
  set_hub_cluster_kubeconfig
  test_hub_cluster_deployment
}

main
