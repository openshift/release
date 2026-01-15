#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Verify Python and black are available
python3 --version
black --version

# Run tests
cd observability/grafana
make test

# Run format
make format

# Check for uncommitted changes
if [[ ! -z "$(git status --short)" ]]; then
  echo "there are some modified files, rerun 'make format' to update them and check the changes in"
  git status
  exit 1
fi

