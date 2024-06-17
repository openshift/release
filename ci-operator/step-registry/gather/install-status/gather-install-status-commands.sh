#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#function createInstallJunit() {
#  EXIT_CODE_CONFIG=3
#  EXIT_CODE_INFRA=4
#  EXIT_CODE_BOOTSTRAP=5
#  EXIT_CODE_CLUSTER=6
#  EXIT_CODE_OPERATORS=7
#  if test -f "${SHARED_DIR}/install-status-new.txt"
#  then
#    EXIT_CODE=`tail -n1 "${SHARED_DIR}/install-status.txt" | awk '{print $1}'`
#    cp "${SHARED_DIR}/install-status.txt" "${ARTIFACT_DIR}/"
#    if [ "$EXIT_CODE" ==  0  ]
#    then
#      set +o errexit
#      grep -q "^$EXIT_CODE_INFRA$" "${SHARED_DIR}/install-status.txt"
#      PREVIOUS_INFRA_FAILURE=$((1-$?))
#      set -o errexit
#
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="$((PREVIOUS_INFRA_FAILURE+7))" failures="$PREVIOUS_INFRA_FAILURE">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration"/>
#        <testcase name="install should succeed: infrastructure"/>
#        <testcase name="install should succeed: cluster bootstrap"/>
#        <testcase name="install should succeed: cluster creation"/>
#        <testcase name="install should succeed: cluster operator stability"/>
#        <testcase name="install should succeed: overall"/>
#EOF
#
#      # If we ultimately succeeded, but encountered at least 1 infra
#      # failure, insert that failure case so CI tracks it as a flake.
#      if [ "$PREVIOUS_INFRA_FAILURE" = 1 ]
#      then
#      cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#        <testcase name="install should succeed: infrastructure">
#          <failure message="">openshift cluster install failed with infrastructure setup</failure>
#        </testcase>
#EOF
#      fi
#
#      cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      </testsuite>
#EOF
#    elif [ "$EXIT_CODE" == "$EXIT_CODE_CONFIG" ]
#    then
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="3" failures="2">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration">
#          <failure message="">openshift cluster install failed with config validation error</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    elif [ "$EXIT_CODE" == "$EXIT_CODE_INFRA" ]
#    then
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="4" failures="2">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration"/>
#        <testcase name="install should succeed: infrastructure">
#          <failure message="">openshift cluster install failed with infrastructure setup</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    elif [ "$EXIT_CODE" == "$EXIT_CODE_BOOTSTRAP" ]
#    then
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="5" failures="2">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration"/>
#        <testcase name="install should succeed: infrastructure"/>
#        <testcase name="install should succeed: cluster bootstrap">
#          <failure message="">openshift cluster install failed with cluster bootstrap</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    elif [ "$EXIT_CODE" == "$EXIT_CODE_CLUSTER" ]
#    then
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="6" failures="2">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration"/>
#        <testcase name="install should succeed: infrastructure"/>
#        <testcase name="install should succeed: cluster bootstrap"/>
#        <testcase name="install should succeed: cluster creation">
#          <failure message="">openshift cluster install failed with cluster creation</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    elif [ "$EXIT_CODE" == "$EXIT_CODE_OPERATORS" ]
#    then
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="7" failures="2">
#        <testcase name="install should succeed: other"/>
#        <testcase name="install should succeed: configuration"/>
#        <testcase name="install should succeed: infrastructure"/>
#        <testcase name="install should succeed: cluster bootstrap"/>
#        <testcase name="install should succeed: cluster creation"/>
#        <testcase name="install should succeed: cluster operator stability">
#          <failure message="">openshift cluster install failed with cluster operator stability failure</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    else
#      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
#      <testsuite name="cluster install" tests="2" failures="2">
#        <testcase name="install should succeed: other">
#          <failure message="">openshift cluster install failed with other errors</failure>
#        </testcase>
#        <testcase name="install should succeed: overall">
#          <failure message="">openshift cluster install failed overall</failure>
#        </testcase>
#      </testsuite>
#EOF
#    fi
#  fi
#}

if test -f "${SHARED_DIR}/e2e-status.txt"
  then
    EXIT_CODE=`tail -n1 "${SHARED_DIR}/e2e-status.txt" | awk '{print $1}'`
    if [ "$EXIT_CODE" ==  0  ]
    then
      echo "Creating junit"
      source ../must-gather/gather-must-gather-commands.sh
      createInstallJunit
      echo "junit created successfully"
    fi
fi
