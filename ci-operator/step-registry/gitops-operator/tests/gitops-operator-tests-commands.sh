#!/usr/bin/env bash

set -x

unset CI

exit_code=0
scripts/openshift-CI-kuttl-tests.sh
kubectl kuttl test test/openshift/e2e/sequential --config test/openshift/e2e/sequential/kuttl-test.yaml --report xml || exit_code=1


# Move results to Artifacts directory
cp ./kuttl-test.xml ${ARTIFACT_DIR}/junit_gitops-sequential.xml

exit $exit_code