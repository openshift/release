#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deleting .gitignore file if it exists"
rm -rf .gitignore

echo "Running go mod vendor"
go mod vendor

if [[ -n $(git diff) ]]; then
  exit 1
fi
