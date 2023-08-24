#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

echo "Logging to oc:"
sh ./oc_login.sh
echo "Executing tests:"
sh ./run.sh

# Collect test reports into $ARTIFACT_DIR
PROJECTS=$PROJECTS

echo "Copying results and xmls to ${ARTIFACT_DIR}"
for PROJECT in ${PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/TEST-*.xml; do
    FILENAME=$(basename $FILE)
    TARGET=${ARTIFACT_DIR}/junit_${FILENAME}
    echo "Collecting ${TARGET}"
    cp $FILE $TARGET
  done
done


