#!/usr/bin/env bash

set -eo pipefail

export JOB_ID="${PROW_JOB_ID:0:8}"

env

.openshift-ci/jobs/integration-tests/run-integration-tests.sh
