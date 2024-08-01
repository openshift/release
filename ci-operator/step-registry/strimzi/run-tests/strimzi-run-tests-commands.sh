#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running the tests"
./run_tests.sh
