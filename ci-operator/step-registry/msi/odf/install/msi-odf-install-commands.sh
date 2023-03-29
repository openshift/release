#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

echo -e "env var injected: $TEST_ENV_VAR"
sleep 3600