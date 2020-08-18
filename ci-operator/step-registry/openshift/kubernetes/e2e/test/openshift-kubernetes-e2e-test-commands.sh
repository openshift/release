#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# The following called script is maintained in openshift/kubernetes
# and added to the kubernetes-test binary. This is simpler to maintain
# since the tests and the wrapper that executes the m can be iterated
# on in a single PR.
test-kubernetes-e2e.sh
