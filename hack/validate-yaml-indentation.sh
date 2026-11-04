#!/bin/bash

# This script ensures that YAML files have consistent indentation.
# It checks for tabs, mixed indentation, and inconsistent indentation width.
# Can optionally also run yamllint for additional validation.

set -o errexit
set -o nounset
set -o pipefail

base_dir="${1:-}"
shift || true  # Shift off first arg, remaining args are passed to the script

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

# The validation image used by ci/prow/yamllint originally did not include git,
# and determining the changed files requires it. Install it on demand; this is a
# no-op once the image ships git.
if ! command -v git >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: git is required to determine changed files and is not installed" >&2
    exit 1
  fi
  echo "git is not installed; installing it to determine changed files" >&2
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git
fi

# Run the Python validation script
# Use --no-strict mode to be less strict about indentation width for existing files
# This focuses on critical issues like tabs and mixed tab/space indentation
# Use --git-diff to only check changed files in CI/PRs
if [[ -n "${GIT_DIFF:-}" ]] || git rev-parse --git-dir > /dev/null 2>&1; then
  python3 "$( dirname "${BASH_SOURCE[0]}" )/validate-yaml-indentation.py" "${base_dir}" --no-strict --git-diff "$@"
else
  python3 "$( dirname "${BASH_SOURCE[0]}" )/validate-yaml-indentation.py" "${base_dir}" --no-strict "$@"
fi

