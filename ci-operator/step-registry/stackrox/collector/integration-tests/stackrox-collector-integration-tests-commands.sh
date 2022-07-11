#!/usr/bin/env bash
set -eo pipefail

function cleanup() {
    .openshift-ci/jobs/teardown-vm.sh
}

trap cleanup EXIT

.openshift-ci/jobs/create-vm.sh
.openshift-ci/jobs/run-integration-tests.sh

