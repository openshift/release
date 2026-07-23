#!/bin/bash

set -e
set -u
set -o pipefail

if  [ "$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE" == "" ]; then
  echo "This installation does not need to create any kerneltype day-2 MachineConfig"
  exit 0
fi

JUNIT_SUITE="Kerneltype Install"
JUNIT_TEST="Pools updated with the new kerneltype"

function create_failed_junit() {
  local SUITE_NAME=$1
  local TEST_NAME=$2
  local FAILURE_MESSAGE=$3

  cat >"${ARTIFACT_DIR}/junit_kernelkype.xml" <<EOF
<testsuite name="$SUITE_NAME" tests="1" failures="1">
  <testcase name="$TEST_NAME">
    <failure message="">$FAILURE_MESSAGE
    </failure>
  </testcase>
</testsuite>
EOF
}

function create_passed_junit() {
  local SUITE_NAME=$1
  local TEST_NAME=$2

  cat >"${ARTIFACT_DIR}/junit_kerneltype.xml" <<EOF
<testsuite name="$SUITE_NAME" tests="1" failures="0">
  <testcase name="$TEST_NAME"/>
</testsuite>
EOF
}

function set_proxy () {
    if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
        echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings"
    fi
}

function validate_params() {
  if  [ "$MCO_CONF_DAY2_INSTALL_KERNEL_MCPS" = "" ]; then
    echo "ERROR: No MachineConfigPool provided"
    exit 255
  fi

  if  [ "$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE" != "realtime" ] && [ "$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE" != "64k-pages" ]; then
    echo "ERROR: kerneltype '$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE' is not allowed. Accepted values: [realtime, 64k-pages]"
    exit 255
  fi
}

function create_machine_configs() {
  local KERNEL_MCPS=$1
  local KERNEL_TYPE=$2

  for MACHINE_CONFIG_POOL in $KERNEL_MCPS; do
    MC_NAME="99-day2-$MACHINE_CONFIG_POOL-kernel-$KERNEL_TYPE"

    echo "Creating $KERNEL_TYPE kerneltype MachineConfig $MC_NAME for pool $MACHINE_CONFIG_POOL"

    oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $MACHINE_CONFIG_POOL
  name: $MC_NAME
spec:
  kernelType: $KERNEL_TYPE
EOF
  done

}

function wait_for_config_to_be_applied() {
  local KERNEL_MCPS=$1
  local KERNEL_TIMEOUT=$2

  for MACHINE_CONFIG_POOL in $KERNEL_MCPS; do
    echo "Waiting for $MACHINE_CONFIG_POOL MachineConfigPool to start updating..."
    if oc wait mcp "$MACHINE_CONFIG_POOL" --for='condition=UPDATING=True' --timeout=300s &>/dev/null ; then
      echo "Pool $MACHINE_CONFIG_POOL has started the update"
    else
      echo "$MACHINE_CONFIG_POOL hast not started the update when the kerneltype was configured"
      create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "$MACHINE_CONFIG_POOL hast not started the update when the kerneltype was configured"
      exit 255
    fi

  done

  for MACHINE_CONFIG_POOL in $KERNEL_MCPS; do
    echo "Waiting for $MACHINE_CONFIG_POOL MachineConfigPool to be updated..."
    if oc wait mcp "$MACHINE_CONFIG_POOL" --for='condition=UPDATED=True' --timeout="$KERNEL_TIMEOUT" 2>/dev/null ; then
      echo "Pool $MACHINE_CONFIG_POOL has been properly updated"
    else
      echo "$MACHINE_CONFIG_POOL could not install the new kerneltype"
      create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "$MACHINE_CONFIG_POOL could not install the new kerneltype"
      exit 255
    fi

  done
}


function check_kerneltype() {
  local KERNEL_MCPS=$1
  local KERNEL_TYPE=$2
  local CHECK_STRING=""

  case $KERNEL_TYPE in
    "realtime")
      CHECK_STRING="rt"
    ;;
    "64k-pages")
      CHECK_STRING="64k"
    ;;
    *)
      echo "Wrong kerneltype $KERNEL_TYPE. Kerneltype not supported."
      exit 255
    ;;
  esac

  for MACHINE_CONFIG_POOL in $KERNEL_MCPS; do
      echo "Checking which kernel is used in MachineConfigPool $MACHINE_CONFIG_POOL nodes"

    for NODE in $(oc get nodes -o name -l "node-role.kubernetes.io/$MACHINE_CONFIG_POOL"); do
      echo "Checking kernel in node $NODE from MachineConfigPool $MACHINE_CONFIG_POOL"

      KERNEL=$(oc -n default debug -q "$NODE" -- chroot /host uname -r)
      echo "Current kernel: $KERNEL"

      if [[ $KERNEL =~ $CHECK_STRING ]]; then
        echo "Kernel OK"
      else
        echo "Wrong kernel. Expected to match string: $CHECK_STRING"

        create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "Node $NODE in MCP $MACHINE_CONFIG_POOL is using kernel $KERNEL instead of the expected kernel $KERNEL_TYPE"
	exit 255
      fi

    done
  done
}

validate_params

set_proxy

create_machine_configs "$MCO_CONF_DAY2_INSTALL_KERNEL_MCPS" "$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE"

wait_for_config_to_be_applied "$MCO_CONF_DAY2_INSTALL_KERNEL_MCPS" "$MCO_CONF_DAY2_INSTALL_KERNEL_TIMEOUT"

oc get nodes -o wide

check_kerneltype   "$MCO_CONF_DAY2_INSTALL_KERNEL_MCPS" "$MCO_CONF_DAY2_INSTALL_KERNEL_TYPE"

create_passed_junit "$JUNIT_SUITE" "$JUNIT_TEST"
