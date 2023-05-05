#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Clone repository with system tests"
git clone https://github.com/Apicurio/apicurio-registry-system-tests

echo "Change directory to system tests in repository"
cd apicurio-registry-system-tests/system-tests

echo "Create target directory"
mkdir target

echo "Download Apicurio Registry CRD into target directory"
wget https://raw.githubusercontent.com/Apicurio/apicurio-registry-operator/1.0.0-v2.0.0.final/packagemanifests/1.0.0-v2.0.0.final/registry.apicur.io_apicurioregistries.yaml -O target/registry.apicur.io_apicurioregistries.yaml

echo "Run the tests"
./scripts/run-interop-tests.sh

echo "Copy logs and xunit to artifacts dir"
cp target/surefire-reports/*.xml "${ARTIFACT_DIR}"