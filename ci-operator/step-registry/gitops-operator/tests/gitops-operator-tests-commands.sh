#!/usr/bin/env bash

set -x

exit_code=0
scripts/openshift-CI-kuttl-tests.sh
unset CI
make e2e-tests-ginkgo || exit_code=1

exit $exit_code