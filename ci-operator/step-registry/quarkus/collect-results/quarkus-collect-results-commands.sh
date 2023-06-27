#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

echo "Copying results and xmls to ${ARTIFACT_DIR}"
ALL_PROJECTS=${PROJECTS:?Can not retrieve the list of projects}
for PROJECT in ${ALL_PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/*.xml; do
    FILENAME=$(basename $FILE)
    echo $FILENAME
    cp $FILE ${ARTIFACT_DIR}/junit_${FILENAME}
  done
done
