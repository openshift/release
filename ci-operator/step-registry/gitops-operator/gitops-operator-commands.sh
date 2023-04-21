#!/usr/bin/env bash

set -o pipefail

scripts/openshift-Interop-kuttl-tests.sh
make e2e-tests-sequential