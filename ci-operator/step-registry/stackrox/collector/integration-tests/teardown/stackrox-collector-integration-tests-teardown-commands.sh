#!/usr/bin/env bash

set -eo pipefail

cci-export JOB_ID "${PROW_JOB_ID:0:8}"

exec .openshift-ci/jobs/integration-tests/teardown-vm.sh

