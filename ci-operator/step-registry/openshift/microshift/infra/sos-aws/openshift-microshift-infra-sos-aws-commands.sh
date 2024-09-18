#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

trap 'generate_junit' EXIT

function generate_junit() {
    if ! test -f "${SHARED_DIR}/install-status.txt"; then
        return 0
    fi

    EXIT_CODE=`tail -n1 "${SHARED_DIR}/install-status.txt" | awk '{print $1}'`
    cp "${SHARED_DIR}/install-status.txt" "${ARTIFACT_DIR}/"
    if [ "$EXIT_CODE" ==  0  ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="5" failures="0">
    <testcase name="install should succeed: cluster bootstrap"/>
    <testcase name="install should succeed: configuration"/>
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: overall"/>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_AWS_EC2_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="3" failures="2">
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: infrastructure">
        <failure message="">Failed to create MicroShift VM</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_AWS_EC2_LOG_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="3" failures="2">
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: infrastructure">
        <failure message="">Failed to retrieve logs from MicroShift VM</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_LVM_INSTALL_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="4" failures="2">
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: cluster bootstrap">
        <failure message="">Failed to setup LVM</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_RPM_INSTALL_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="5" failures="2">
    <testcase name="install should succeed: cluster bootstrap"/>
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: other">
        <failure message="">Failed to install MicroShift</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_CONFORMANCE_SETUP_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="5" failures="2">
    <testcase name="install should succeed: cluster bootstrap"/>
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: configuration">
        <failure message="">Failed to configure host for MicroShift conformance</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_PCP_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="5" failures="2">
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: cluster bootstrap"/>
    <testcase name="install should succeed: configuration">
        <failure message="">Failed to install pcp in MicroShift VM</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_WAIT_CLUSTER_FAILURE" ]; then
        cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
<testsuite name="cluster install" tests="5" failures="2">
    <testcase name="install should succeed: other"/>
    <testcase name="install should succeed: infrastructure"/>
    <testcase name="install should succeed: cluster bootstrap"/>
    <testcase name="install should succeed: configuration">
        <failure message="">Failed to install pcp in MicroShift VM</failure>
    </testcase>
    <testcase name="install should succeed: overall">
        <failure message="">MicroShift install failed overall</failure>
    </testcase>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="2" failures="2">
        <testcase name="install should succeed: other">
          <failure message="">MicroShift cluster install failed with other errors</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">MicroShift cluster install failed overall</failure>
        </testcase>
EOF
    fi
    cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
</testsuite>
EOF
}

ssh "${INSTANCE_PREFIX}" <<'EOF'
  set -x
  if ! hash sos ; then
    sudo touch /tmp/sosreport-command-does-not-exist
    exit 0
  fi

  plugin_list="container,network"
  if ! sudo sos report --list-plugins | grep 'microshift.*inactive' ; then
    plugin_list+=",microshift"
  fi

  if sudo sos report --batch --all-logs --tmp-dir /tmp -p ${plugin_list} -o logs ; then
    sudo chmod +r /tmp/sosreport-*
  else
    sudo touch /tmp/sosreport-command-failed
  fi
EOF
scp "${INSTANCE_PREFIX}":/tmp/sosreport-* "${ARTIFACT_DIR}" || true
