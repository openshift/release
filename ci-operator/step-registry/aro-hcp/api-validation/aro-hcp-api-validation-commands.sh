#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Verify Node.js is available
node --version
npm --version

# Unset VERSION to prevent CI environment variable from overriding Makefile default
# The Makefile uses VERSION ?= v20251223preview, but CI may have VERSION set to something else
unset VERSION

# Generate
cd api
make generate

# Format (from root)
cd ..
make fmt

# Check for uncommitted changes
if [[ -n "$(git status --short)" ]]; then
  echo "Uncommitted changes detected. Please run 'make generate' and 'make fmt', then commit."
  git status
  git diff
  exit 1
fi

# Validate and lint
cd api
make validate-examples
make lint-openapi