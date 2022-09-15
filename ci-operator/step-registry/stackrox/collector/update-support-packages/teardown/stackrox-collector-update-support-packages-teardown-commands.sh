#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/update-support-packages/env.sh

.openshift-ci/jobs/integration-tests/gcloud-init.sh

.openshift-ci/jobs/integration-tests/teardown-vm.sh

