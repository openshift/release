#!/usr/bin/env bash
set -eo pipefail

function cleanup() {
    .openshift-ci/jobs/integration-tests/teardown-vm.sh
}

trap cleanup EXIT

env

.openshift-ci/jobs/integration-tests/create-vm.sh
.openshift-ci/jobs/integration-tests/run-integration-tests.sh

