#!/bin/bash

# This script runs a read-and-write program on all Prow job configs to make
# them ordered in a deterministic way

set -o errexit
set -o nounset
set -o pipefail

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

determinize-prow-jobs --prow-jobs-dir "${ci_operator_dir}/jobs"
