#!/bin/bash

# This script runs the pj-rehearse tool after copying the content of the
# redhat-openshift-ecosystem/release repository to the working directory,
# so that the content of that repository is considered in rehearsal decisions.

set -o errexit
set -o nounset
set -o pipefail

echo "Copying redhat-openshift-ecosystem/release content"
cp -Rn ../../redhat-openshift-ecosystem/release/ci-operator/config/* ./ci-operator/config/
cp -Rn ../../redhat-openshift-ecosystem/release/ci-operator/jobs/* ./ci-operator/jobs/

if echo "${JOB_SPEC}"|grep -q '"author":"openshift-bot"'; then
  echo "Pull request is created by openshift-bot, skipping rehearsal"
  exit 0
fi

echo "Running pj-rehearse"
exec pj-rehearse "$@"
