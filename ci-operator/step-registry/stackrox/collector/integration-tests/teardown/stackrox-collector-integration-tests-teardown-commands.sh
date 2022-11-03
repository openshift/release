#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/integration-tests/env.sh

.openshift-ci/scripts/gcloud-init.sh

make -C ansible BUILD_TYPE=ci integration-tests-teardown
