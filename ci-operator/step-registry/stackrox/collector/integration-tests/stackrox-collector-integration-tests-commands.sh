#!/usr/bin/env bash

set -eo pipefail

env

export JOB_ID="${PROW_JOB_ID:0:8}"

.openshift-ci/jobs/integration-tests/run-integration-tests.sh
