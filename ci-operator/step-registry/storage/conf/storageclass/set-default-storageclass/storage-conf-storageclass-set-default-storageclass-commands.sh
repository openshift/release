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
  # Temporarily avoid known issue: https://issues.redhat.com/browse/OCPBUGS-14824
  for i in $(seq 1 6); do
    run_command "oc annotate sc storageclass.kubernetes.io/is-default-class=false --all --overwrite"
    get_default_sc
    if [ "${CURRENT_DEFAULT_SC}" == "" ] ; then
        echo "Remove all default storage classes successfully after retry $((i - 1)) times"
        break
    fi
    sleep 5
  done
  if [ "${CURRENT_DEFAULT_SC}" != "" ] ; then
    echo "Remove all default storage classes failed" && exit 1
  fi
}

function set_required_sc_as_default () {
  run_command "oc annotate sc ${REQUIRED_DEFAULT_STORAGECLASS} storageclass.kubernetes.io/is-default-class=true --overwrite"
}

function wait_for_default_sc () {
  for i in $(seq 1 12); do
      get_default_sc
      if [ "${CURRENT_DEFAULT_SC}" == "${REQUIRED_DEFAULT_STORAGECLASS}" ]; then
          echo "${REQUIRED_DEFAULT_STORAGECLASS} is the default storageclass"
          return 0
      fi
      echo "Waiting for operator to set ${REQUIRED_DEFAULT_STORAGECLASS} as default (attempt ${i}/12)..."
      sleep 10
  done
  echo "ERROR: ${REQUIRED_DEFAULT_STORAGECLASS} did not become the default storageclass" && exit 1
}

set_proxy
get_default_sc

function version_ge() {
  # Returns 0 (true) if $1 >= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d'.' -f1,2 || echo "0.0")

# On OCP 4.22+, the LVMS operator manages the default SC annotation via
# Server-Side Apply with ForceOwnership. Removing the annotation from the
# operator-managed SC causes a race — the operator immediately restores it.
# Instead, remove all default annotations and wait for the operator to
# reconcile its SC as the default.
# Only apply this path when LVMS operator is actually installed.
LVMS_INSTALLED=$(oc get csv -A 2>/dev/null | grep -c "lvms-operator" || true)

if version_ge "${OCP_VERSION}" "4.22" && [ "${LVMS_INSTALLED}" -gt 0 ] && oc get sc "${REQUIRED_DEFAULT_STORAGECLASS}" &>/dev/null; then
    echo "OCP ${OCP_VERSION}: Removing default annotation from all storageclasses, operator will reconcile ${REQUIRED_DEFAULT_STORAGECLASS}"
    run_command "oc annotate sc storageclass.kubernetes.io/is-default-class=false --all --overwrite"
    wait_for_default_sc
else
    remove_all_default_sc_annotations
    set_required_sc_as_default
fi

# For debugging
get_current_sc
