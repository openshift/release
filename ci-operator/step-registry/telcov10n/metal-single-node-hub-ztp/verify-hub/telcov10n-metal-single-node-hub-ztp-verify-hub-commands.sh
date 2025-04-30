#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

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
  test_name=$1
  test_results_xml_output=${ARTIFACT_DIR}/junit_${test_name}-test-results.xml
  pytest ${PYTEST_VERBOSITY} ${tc_file} --junitxml=${test_results_xml_output}
}

function test_deployment_and_services {

  echo "************ telcov10n-vhub Generate Test results ************"

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

@pytest.mark.parametrize("url", [
    ("$($oc_hub whoami --show-console)", 200),
    ("$($oc_hub get managedcluster local-cluster -ojsonpath='{.spec.managedClusterClientConfigs[0].url}')", 403),
])
def test_http_endpoint(url):
    socks5_proxy = "${SOCKS5_PROXY}"
    proxies = {"http": socks5_proxy, "https": socks5_proxy} if len(socks5_proxy) > 0 else None
    response = requests.get(url[0], verify=False, proxies=proxies)
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
EOF-PYTEST

  run_pytest check_hub_installation
}

function assert_expected_resources_are_available {

  echo "************ telcov10n Assert the expected resources are available ************"

  set -x
  for ((attempts = 0 ; attempts <  ${max_attempts:=10} ; attempts++)); do
    {
      $oc_hub get no,clusterversion,mcp,co,sc,pv &&
      $oc_hub get subscriptions.operators,OperatorGroup,pvc -A &&
      $oc_hub get managedcluster &&
      set +x &&
      return ;
    } ||
    sleep 1m
  done

  echo "[FAIL] Not all expected resources are available..."
  exit 1
}

function assert_console_is_available {

  echo "************ telcov10n Assert the console is available ************"

  set -x
  for ((attempts = 0 ; attempts <  ${max_attempts:=10} ; attempts++)); do
    {
      console_pods="$($oc_hub -n openshift-console get pod -oname)" &&
      $oc_hub -n openshift-console wait --for=condition=Ready ${console_pods} --timeout 5m &&
      router_pods="$($oc_hub -n openshift-ingress get pod -oname)" &&
      $oc_hub -n openshift-ingress wait --for=condition=Ready ${router_pods} --timeout 5m &&
      authentication_pods="$($oc_hub -n openshift-authentication get pod -oname)" &&
      $oc_hub -n openshift-authentication wait --for=condition=Ready ${authentication_pods} --timeout 5m &&
      $oc_hub get co &&
      $oc_hub whoami --show-console &&
      [ "$($oc_hub get managedcluster local-cluster -ojsonpath='{.spec.managedClusterClientConfigs[0].url}')" != "" ] &&
      set +x &&
      return ;
    } ||
    sleep 1m
  done

  echo "[FAIL] Console not reachable..."
  exit 1
}

function test_hub_cluster_deployment {

  echo "************ telcov10n Test Hub deployment ************"

  set -x
  diff -u ${KUBECONFIG} ${hub_kubeconfig} || \
    ( echo "Wrong KUBECONFIG file retreived!!! Exiting..." && exit 1 )
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
  assert_expected_resources_are_available
  assert_console_is_available
  test_hub_cluster_deployment
}

main
