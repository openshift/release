#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

pytest /tmp/mock_private/test_mock_private.py -vv --junitxml=${SHARED_DIR}/xunit_output.xml

echo "finished"