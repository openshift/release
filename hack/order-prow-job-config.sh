#!/bin/bash

# This script runs a read-and-write program on all Prow job configs to make
# them ordered in a deterministic way

set -o errexit
set -o nounset
set -o pipefail

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

ci_operator_dir="${base_dir}/ci-operator"

cmd=sanitize-prow-jobs
if ! type $cmd &>/dev/null; then cmd=determinize-prow-jobs; fi

$cmd --prow-jobs-dir "${ci_operator_dir}/jobs" --config-path "${base_dir}/core-services/sanitize-prow-jobs/_config.yaml"
