#!/bin/bash

# This script updates the Prow configuration checked into git by generating it
# from the CI Operator confguration.

set -o errexit
set -o nounset
set -o pipefail

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

ci-operator-prowgen --from-dir "${ci_operator_dir}/config" --to-dir "${ci_operator_dir}/jobs"