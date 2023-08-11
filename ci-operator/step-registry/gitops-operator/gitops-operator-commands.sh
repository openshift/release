#!/usr/bin/env bash

set -x

unset CI
scripts/openshift-CI-kuttl-tests.sh
kubectl kuttl test test/openshift/e2e/sequential --config test/openshift/e2e/sequential/kuttl-test.yaml --report xml

# Move results to Artifacts directory
find . -type f -name "*.xml"
cp ./kuttl-test.xml ${ARTIFACT_DIR}/junit_gitops-sequential.xml