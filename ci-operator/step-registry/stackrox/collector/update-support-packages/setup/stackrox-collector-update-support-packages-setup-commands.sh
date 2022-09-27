#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/update-support-packages/env.sh

.openshift-ci/scripts/gcloud-init.sh
.openshift-ci/scripts/vms/create-vm.sh

