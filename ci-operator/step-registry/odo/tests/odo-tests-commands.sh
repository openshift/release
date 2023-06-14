#!/bin/bash

set -o nounset
set -x

status=0

# Run tests
echo "Executing odo tests..."
scripts/openshiftci-presubmit-all-tests.sh || status="$?" || :

# Copy Results and artifacts to $ARTIFACT_DIR
cp -r test-*.xml ${ARTIFACT_DIR}/ 2>/dev/null || :

# Prepend junit_ to result xml files
rename '/test-' '/junit_test-' ${ARTIFACT_DIR}/test-*.xml 2>/dev/null || :

exit $status
