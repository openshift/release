#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Change to eco-ci-cd directory and run the external Python script
cd /eco-ci-cd/scripts
python3 fail_if_any_test_failed.py
