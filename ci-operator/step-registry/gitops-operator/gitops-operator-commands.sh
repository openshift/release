#!/usr/bin/env bash

set -x

unset CI
scripts/openshift-CI-kuttl-tests.sh
kubectl kuttl test test/openshift/e2e/sequential --config test/openshift/e2e/sequential/kuttl-test.yaml --report xml
cp openshift-gitops-e2e.xml ${ARTIFACT_DIR}/junit_gitops-sequential.xml