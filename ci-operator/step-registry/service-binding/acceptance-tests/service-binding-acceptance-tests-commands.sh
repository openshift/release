#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

status=0
make -k VERBOSE=2 -o registry-login test-acceptance-with-bundle test-acceptance-artifacts || status="$?" || :
rename TESTS junit_TESTS /logs/artifacts/acceptance-tests/TESTS*.xml 2>/dev/null || :
exit $status