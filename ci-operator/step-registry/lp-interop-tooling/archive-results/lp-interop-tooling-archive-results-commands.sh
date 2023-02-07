#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Copy the specified file to $ARTIFACT_DIR/lp_interop_results.xml
echo "Copying SHARED_DIR/${RESULTS_FILE} to ARTIFACT_DIR/lp_interop_results.xml"
cp $SHARED_DIR/$RESULTS_FILE $ARTIFACT_DIR/lp_interop_results.xml
