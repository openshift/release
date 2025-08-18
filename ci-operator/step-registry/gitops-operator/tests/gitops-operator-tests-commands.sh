#!/usr/bin/env bash

set -x

unset CI

exit_code=0
scripts/openshift-CI-kuttl-tests.sh
make e2e-tests-sequential e2e-tests-parallel || exit_code=1

exit $exit_code