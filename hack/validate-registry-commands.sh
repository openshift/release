#!/usr/bin/env bash
set -euo pipefail

# This script checks all shell scripts in the step registry and errors if shellcheck detects error or warning level syntax issues

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

find "${base_dir}/ci-operator/step-registry" -name "*.sh" -print0 | xargs -0 -n1 shellcheck -S warning
