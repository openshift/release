#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

# Test Openshift Virtualization pages on ACM cluster, make sure the UI flow works smoothly.
git clone https://github.com/kubevirt-ui/kubevirt-plugin.git
./test-cypress.sh -s "tests/acm.cy.ts"