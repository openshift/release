#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/update-support-packages/env.sh

env

.openshift-ci/jobs/integration-tests/gcloud-init.sh
