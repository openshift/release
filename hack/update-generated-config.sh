#!/bin/bash

# This script updates the Prow configuration checked into git by generating it
# from the CI Operator confguration.

set -o errexit
set -o nounset
set -o pipefail

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

ci-operator-prowgen --config-dir "${ci_operator_dir}/config" --prow-jobs-dir "${ci_operator_dir}/jobs"