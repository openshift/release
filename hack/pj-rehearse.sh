#!/bin/bash

# This script runs the pj-rehearse tool after copying the content of the
# redhat-operator-ecosystem/release repository to the working directory,
# so that the content of that repository is considered in rehearsal decisions.

set -o errexit
set -o nounset
set -o pipefail

echo "Copying redhat-operator-ecosystem/release content"
cp -Rn ../../redhat-operator-ecosystem/release/ci-operator/config/* ./ci-operator/config/
cp -Rn ../../redhat-operator-ecosystem/release/ci-operator/jobs/* ./ci-operator/jobs/

echo "Running pj-rehearse"
pj-rehearse "$@"
