#!/bin/bash

set -e
set -u
set -o pipefail

JUNIT_SUITE="Remove Kerneltype and Extensions"
JUNIT_TEST="Kerneltype and extensions MachineConfigs removed successfully"

emit_junit() {
  local rc=${1:-0}
  local junit_file="${ARTIFACT_DIR}/junit_remove_kerneltype_extensions.xml"
  local fc=0 fx=""

  if (( rc != 0 )); then
    fc=1
    fx="<failure message=\"\">Step failed with exit code ${rc}</failure>"
  fi

  cat >"${junit_file}" <<EOF
<testsuite name="${JUNIT_SUITE}" tests="1" failures="${fc}">
  <testcase name="${JUNIT_TEST}">
    ${fx}
  </testcase>
</testsuite>
EOF
}

trap 'rc=$?; emit_junit ${rc}; exit ${rc}' EXIT

if [[ -z "${MCO_CONF_DAY2_REMOVE_MCPS}" ]]; then
  echo "No MachineConfigPools provided, skipping"
  exit 0
fi

function set_proxy() {
  if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
    echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
  else
    echo "No proxy settings"
  fi
}

function get_kernel_check_string() {
  local KERNEL_TYPE=$1

  case $KERNEL_TYPE in
    "realtime")
      echo "rt"
    ;;
    "64k-pages")
      echo "64k"
    ;;
  esac
}

function check_kerneltype() {
  local MCPS=$1
  local EXPECTED_TYPE=$2
  local CHECK_STRING

  CHECK_STRING=$(get_kernel_check_string "${EXPECTED_TYPE}")

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Checking kernel in MachineConfigPool ${MACHINE_CONFIG_POOL} nodes"

    for NODE in $(oc get nodes -o name -l "node-role.kubernetes.io/${MACHINE_CONFIG_POOL}"); do
      KERNEL=$(oc -n default debug -q "${NODE}" -- chroot /host uname -r)
      echo "Node ${NODE}: kernel ${KERNEL}"

      if [[ $KERNEL =~ $CHECK_STRING ]]; then
        echo "OK: kernel matches expected type '${EXPECTED_TYPE}'"
      else
        echo "ERROR: kernel '${KERNEL}' does not match expected type '${EXPECTED_TYPE}' (expected string: ${CHECK_STRING})"
        exit 1
      fi
    done
  done
}

function check_default_kernel() {
  local MCPS=$1

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Checking kernel in MachineConfigPool ${MACHINE_CONFIG_POOL} nodes"

    for NODE in $(oc get nodes -o name -l "node-role.kubernetes.io/${MACHINE_CONFIG_POOL}"); do
      KERNEL=$(oc -n default debug -q "${NODE}" -- chroot /host uname -r)
      echo "Node ${NODE}: kernel ${KERNEL}"

      if [[ $KERNEL =~ rt ]] || [[ $KERNEL =~ 64k ]]; then
        echo "ERROR: node ${NODE} is still using a non-default kernel '${KERNEL}'"
        exit 1
      else
        echo "OK: node is using default kernel"
      fi
    done
  done
}

function check_extensions_present() {
  local MCPS=$1

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Checking extensions are present in MachineConfigPool ${MACHINE_CONFIG_POOL} nodes"

    for NODE in $(oc get nodes -o name -l "node-role.kubernetes.io/${MACHINE_CONFIG_POOL}"); do
      echo "Checking rpm-ostree status on node ${NODE}"

      local STATUS
      STATUS=$(oc -n default debug -q "${NODE}" -- chroot /host rpm-ostree status)
      echo "${STATUS}"

      if echo "${STATUS}" | grep -q "LayeredPackages"; then
        echo "OK: LayeredPackages found on ${NODE}, extensions are installed"
      else
        echo "ERROR: no LayeredPackages found on ${NODE}, extensions are not installed"
        exit 1
      fi
    done
  done
}

function check_extensions_absent() {
  local MCPS=$1

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Checking extensions are removed from MachineConfigPool ${MACHINE_CONFIG_POOL} nodes"

    for NODE in $(oc get nodes -o name -l "node-role.kubernetes.io/${MACHINE_CONFIG_POOL}"); do
      echo "Checking rpm-ostree status on node ${NODE}"

      local STATUS
      STATUS=$(oc -n default debug -q "${NODE}" -- chroot /host rpm-ostree status)
      echo "${STATUS}"

      if echo "${STATUS}" | grep -q "LayeredPackages"; then
        echo "ERROR: LayeredPackages still present on ${NODE}, extensions have not been removed"
        exit 1
      else
        echo "OK: no LayeredPackages found on ${NODE}, extensions have been removed"
      fi
    done
  done
}

function get_kerneltype_from_mc() {
  local MC_NAME=$1

  oc get mc "${MC_NAME}" -o jsonpath='{.spec.kernelType}'
}

function delete_machineconfigs() {
  local MCPS=$1

  for MACHINE_CONFIG_POOL in $MCPS; do
    local KERNEL_MC="99-${MACHINE_CONFIG_POOL}-kernel-realtime"
    local KERNEL_64K_MC="99-${MACHINE_CONFIG_POOL}-kernel-64k-pages"
    local EXTENSIONS_MC="99-${MACHINE_CONFIG_POOL}-extensions"

    for MC_NAME in $KERNEL_MC $KERNEL_64K_MC $EXTENSIONS_MC; do
      if oc get mc "${MC_NAME}" &>/dev/null; then
        echo "Deleting MachineConfig ${MC_NAME}"
        oc delete mc "${MC_NAME}"
      else
        echo "MachineConfig ${MC_NAME} not found, skipping"
      fi
    done
  done
}

function wait_for_config_to_be_applied() {
  local MCPS=$1
  local TIMEOUT=$2

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Waiting for ${MACHINE_CONFIG_POOL} MachineConfigPool to start updating..."
    if oc wait mcp "${MACHINE_CONFIG_POOL}" --for='condition=UPDATING=True' --timeout=300s &>/dev/null; then
      echo "Pool ${MACHINE_CONFIG_POOL} has started the update"
    else
      echo "Pool ${MACHINE_CONFIG_POOL} did not enter UPDATING state. It may already be up to date."
    fi
  done

  for MACHINE_CONFIG_POOL in $MCPS; do
    echo "Waiting for ${MACHINE_CONFIG_POOL} MachineConfigPool to be updated..."
    if oc wait mcp "${MACHINE_CONFIG_POOL}" --for='condition=UPDATED=True' --timeout="${TIMEOUT}" 2>/dev/null; then
      echo "Pool ${MACHINE_CONFIG_POOL} has been properly updated"
    else
      echo "ERROR: ${MACHINE_CONFIG_POOL} could not finish updating after removing MachineConfigs"
      exit 1
    fi
  done
}

set_proxy

echo "=========================================="
echo "Pre-removal verification"
echo "=========================================="

# Check kerneltype before removal
FOUND_KERNEL=false
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_REMOVE_MCPS}; do
  for MC_NAME in "99-${MACHINE_CONFIG_POOL}-kernel-realtime" "99-${MACHINE_CONFIG_POOL}-kernel-64k-pages"; do
    if oc get mc "${MC_NAME}" &>/dev/null; then
      KERNEL_TYPE=$(get_kerneltype_from_mc "${MC_NAME}")
      echo "Found kerneltype MachineConfig ${MC_NAME} with type '${KERNEL_TYPE}'"
      echo "Verifying nodes in pool ${MACHINE_CONFIG_POOL} are using kernel '${KERNEL_TYPE}'..."
      check_kerneltype "${MACHINE_CONFIG_POOL}" "${KERNEL_TYPE}"
      FOUND_KERNEL=true
    fi
  done
done

# Check extensions before removal
FOUND_EXTENSIONS=false
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_REMOVE_MCPS}; do
  MC_NAME="99-${MACHINE_CONFIG_POOL}-extensions"
  if oc get mc "${MC_NAME}" &>/dev/null; then
    echo "Found extensions MachineConfig ${MC_NAME}"
    check_extensions_present "${MACHINE_CONFIG_POOL}"
    FOUND_EXTENSIONS=true
  fi
done

echo ""
echo "=========================================="
echo "Removing MachineConfigs"
echo "=========================================="

delete_machineconfigs "${MCO_CONF_DAY2_REMOVE_MCPS}"

wait_for_config_to_be_applied "${MCO_CONF_DAY2_REMOVE_MCPS}" "${MCO_CONF_DAY2_REMOVE_TIMEOUT}"

echo ""
echo "=========================================="
echo "Post-removal verification"
echo "=========================================="

oc get nodes -o wide

if [[ "${FOUND_KERNEL}" == "true" ]]; then
  echo "Verifying nodes are using the default kernel..."
  check_default_kernel "${MCO_CONF_DAY2_REMOVE_MCPS}"
fi

if [[ "${FOUND_EXTENSIONS}" == "true" ]]; then
  echo "Verifying extensions have been removed..."
  check_extensions_absent "${MCO_CONF_DAY2_REMOVE_MCPS}"
fi

echo ""
echo "=========================================="
echo "All verifications passed successfully"
echo "=========================================="
oc get mcp
