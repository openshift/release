#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# WIP

function copyArtifacts() {
  echo "Rename JUnit files"
  rename TEST junit_TEST target/surefire-reports/*.xml

  echo "Remove unnecessary comma in decimal numbers in JUnit files"
  sed -i -r 's/([0-9]),([0-9])/\1\2/g' target/surefire-reports/*.xml

  echo "Copy JUnit files into artifacts dir"
  cp target/surefire-reports/*.xml "${ARTIFACT_DIR}"
}

trap copyArtifacts SIGINT SIGTERM ERR EXIT

echo "Run the tests"
./scripts/run-interop-tests.sh
