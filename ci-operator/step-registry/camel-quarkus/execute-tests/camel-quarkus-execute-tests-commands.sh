#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Collect test reports into $ARTIFACT_DIR
PROJECTS=$PROJECTS

sleep 4h

echo "Copying results and xmls to ${ARTIFACT_DIR}"
for PROJECT in ${PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/TEST-*.xml; do
    FILENAME=$(basename $FILE)
    TARGET=${ARTIFACT_DIR}/junit_${FILENAME}
    echo "Collecting ${TARGET}"
    cp $FILE $TARGET
  done
done
