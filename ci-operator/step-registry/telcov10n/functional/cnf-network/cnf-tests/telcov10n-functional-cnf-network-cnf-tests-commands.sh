#!/bin/bash
set -e
set -o pipefail

date
echo "Test report"
echo '<testsuites>
  <testsuite name="telco-verification" errors="0" failures="0" skipped="0" tests="2" time="1.568" timestamp="2025-04-04T09:31:10.725587" hostname="telcov10n-functional-cnf-network-cnf-tests">
    <testcase classname="telcov10n-functional-cnf-network-cnf-tests" name="[sig-telco-verification] Spoke cluster operators are ready" time="0.915"/>
    <testcase classname="telcov10n-functional-cnf-network-cnf-tests" name="[sig-telco-verification] Spoke cluster deployed successfully" time="0.504"/>
  </testsuite>
</testsuites>' > ${ARTIFACT_DIR}/junit_draft_report.xml
