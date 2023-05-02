#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Download repository with tests"
git clone https://github.com/Apicurio/apicurio-registry-system-tests

echo "Change directory to system tests in repository"
cd apicurio-registry-system-tests/system-tests

echo "Run the tests"
./scripts/run-interop-tests.sh

echo "Copy logs and xunit to artifacts dir"
cp target/surefire-reports/*.xml "${ARTIFACT_DIR}"