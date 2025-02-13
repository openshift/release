#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

trap 'FRC=$?; createMTOJunit' EXIT TERM

# Generate the Junit for MTO
function createMTOJunit() {
    echo "Generating the Junit for MTO"
    filename="import-MTO"
    testsuite="MTO"
    if (( FRC == 0 )); then
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00003:lwan:Run e2e test against Multiarch Tuning Operator should succeed"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00003:lwan:Run e2e test against Multiarch Tuning Operator should succeed">
    <failure message="">Some of testcases failed, please check the detail from log</failure>
  </testcase>
</testsuite>
EOF
    fi
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Run e2e against Multiarch Tuning Operator"
make e2e
