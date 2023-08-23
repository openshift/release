#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Collect test reports into $ARTIFACT_DIR
PROJECTS=$PROJECTS

mvn --version
sh ./oc_login.sh
source "$SDKMAN_DIR/bin/sdkman-init.sh"
sh ./run.sh

echo "Copying results and xmls to ${ARTIFACT_DIR}"
for PROJECT in ${PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/TEST-*.xml; do
    FILENAME=$(basename $FILE)
    TARGET=${ARTIFACT_DIR}/junit_${FILENAME}
    echo "Collecting ${TARGET}"
    cp $FILE $TARGET
  done
done
