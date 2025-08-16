#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

# Test Openshift Virtualization pages on ACM cluster, make sure the UI flow works smoothly.
cd /tmp/
git clone https://github.com/kubevirt-ui/kubevirt-plugin.git
cd ./kubevirt-plugin/
./test-cypress.sh -s "tests/acm.cy.ts"