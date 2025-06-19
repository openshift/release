#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

pip install --user junitparser

# Change to eco-ci-cd directory and run the external Python script
cd /eco-ci-cd/scripts
python3 fail_if_any_test_failed.py
