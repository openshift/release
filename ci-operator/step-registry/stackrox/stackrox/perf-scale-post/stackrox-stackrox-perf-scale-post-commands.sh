#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-perf-scale-post"

exec scripts/ci/jobs/ocp-perf-scale-tests-post.sh
