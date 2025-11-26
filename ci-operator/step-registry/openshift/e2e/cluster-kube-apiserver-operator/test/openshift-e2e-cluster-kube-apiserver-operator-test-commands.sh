#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Run the cluster-kube-apiserver-operator e2e tests
make test-e2e JUNITFILE=${ARTIFACT_DIR}/junit_report.xml --warn-undefined-variables
