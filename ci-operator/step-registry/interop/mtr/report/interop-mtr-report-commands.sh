#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "MTR XUNIT RESULTS: "
cat ${SHARED_DIR}/xunit_output.xml
