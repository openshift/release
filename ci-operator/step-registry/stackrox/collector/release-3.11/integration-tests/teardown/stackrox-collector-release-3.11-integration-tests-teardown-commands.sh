#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/integration-tests/env.sh

.openshift-ci/jobs/integration-tests/gcloud-init.sh
.openshift-ci/jobs/integration-tests/teardown-vm.sh
