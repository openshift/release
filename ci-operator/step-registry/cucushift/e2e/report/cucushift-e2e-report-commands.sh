#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# only exit 0 if junit result has no failures
echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
    exit 0
else
    echo "There are ${failures} test failures"
    exit 1
fi
