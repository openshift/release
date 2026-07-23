#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Write a flat context file to SHARED_DIR so the qe-agent post-step can detect failures.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "distributed-tracing/tests/disconnected/distributed-tracing-tests-disconnected-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {}
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

# Unset environment variables which conflict with Chainsaw
unset NAMESPACE

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#Copy the distributed-tracing-qe repo files to a writable directory.
cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

# Execute Distributed Tracing tests
chainsaw test \
--quiet \
--report-name "junit_distributed_tracing_disconnected" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-disconnected
