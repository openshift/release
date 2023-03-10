#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function get_current_sc() {
    run_command "oc get sc"
}

function get_default_sc() {
    CURRENT_DEFAULT_SC=$(oc get sc -ojsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
    echo "Current default storageclass is:" "${CURRENT_DEFAULT_SC}"
}

function remove_all_default_sc_annotations () {
  if [ -z "${CURRENT_DEFAULT_SC}" ]
  then
      echo "Currently no default storageclass is set, no need to remove"
  else
      for SC in ${CURRENT_DEFAULT_SC}
      do
        oc annotate sc "${SC}" "storageclass.kubernetes.io/is-default-class=false" --overwrite
      done
  fi
}

function set_cluster_csi_driver_sc_state_unmanaged () {
  local ret=0
  local provisioner=""
  run_command "oc get sc ${EXPECTED_DEFAULT_STORAGECLASS}" || ret=$?
  if [[ ! $ret -eq 0 ]]; then
      echo "Storageclass ${EXPECTED_DEFAULT_STORAGECLASS} is not exist, skip set its clustercsidriver 'storageClassState' as 'Unmanaged' state."
  else
      provisioner=$(oc get sc/"${EXPECTED_DEFAULT_STORAGECLASS}" -ojsonpath='{.provisioner}')
      run_command "oc get clustercsidriver ${provisioner}" || ret=$?
      if [[ ! $ret -eq 0 ]]; then
        echo "clustercsidriver/${provisioner} is not exist, skip set 'storageClassState' as 'Unmanaged' state."
      else
          oc patch clustercsidriver "${provisioner}" -p '[{"op":"replace","path":"/spec/storageClassState","value":"Unmanaged"}]'  --type json
      fi  
  fi
}

function set_expected_sc_as_default () {
  ret=0
  run_command "oc get sc ${EXPECTED_DEFAULT_STORAGECLASS}" || ret=$?
  if [[ ! $ret -eq 0 ]]; then
      echo "Storageclass ${EXPECTED_DEFAULT_STORAGECLASS} is not exist, skip setting."
  else
      oc annotate sc "${EXPECTED_DEFAULT_STORAGECLASS}" "storageclass.kubernetes.io/is-default-class=true" --overwrite
  fi
}

set_proxy
get_default_sc
set_cluster_csi_driver_sc_state_unmanaged
remove_all_default_sc_annotations
set_expected_sc_as_default
get_current_sc
