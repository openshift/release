#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


# run the test execution script
./../execute_alc_interop_commands.sh

# Copy the test cases results to an external directory
cp -r results $ARTIFACT_DIR/