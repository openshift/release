#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Copying results and xmls to ${ARTIFACT_DIR}"
for PROJECT in ${PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/*.xml; do
    FILENAME=$(basename $FILE)
    echo $FILENAME
    cp $FILE ${ARTIFACT_DIR}/$FILENAME
  done
done
