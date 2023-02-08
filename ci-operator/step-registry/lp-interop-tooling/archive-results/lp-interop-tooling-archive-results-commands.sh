#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Create the target filepath
TARGET_FILEPATH="${ARTIFACT_DIR}/${RESULTS_FILE%".xml"}__lp_interop_results.xml"

# Copy the specified file to $ARTIFACT_DIR/lp_interop_results.xml
echo "Copying SHARED_DIR/${RESULTS_FILE} to ARTIFACT_DIR/lp_interop_results.xml"
cp $SHARED_DIR/$RESULTS_FILE $TARGET_FILEPATH
