#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# create link for oc to kubectl
extended-platform-tests run all --dry-run | grep -E "73289"|grep -E ""