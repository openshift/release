#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

make e2e-test-openshift-setup
