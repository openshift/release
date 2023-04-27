#!/usr/bin/env bash

set -o pipefail

scripts/openshift-interop-kuttl-tests.sh
make e2e-tests-sequential