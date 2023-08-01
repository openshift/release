#!/usr/bin/env bash

set -o pipefail

unset CI
scripts/openshift-CI-kuttl-tests.sh
make e2e-tests-sequential
make e2e-tests-parallel