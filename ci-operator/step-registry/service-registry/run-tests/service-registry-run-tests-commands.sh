#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Run the tests"
./scripts/run-interop-tests.sh

echo "Rename JUnit files"
rename TEST junit_TEST target/surefire-reports/*.xml

echo "Copy logs and xunit to artifacts dir"
cp target/surefire-reports/*.xml "${ARTIFACT_DIR}"