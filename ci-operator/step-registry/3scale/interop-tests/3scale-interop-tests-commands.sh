#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running 3scale interop tests"
make smoke
