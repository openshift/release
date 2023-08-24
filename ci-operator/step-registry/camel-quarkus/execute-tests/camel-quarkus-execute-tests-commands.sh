#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Collect test reports into $ARTIFACT_DIR
PROJECTS=$PROJECTS

# source sdkman
set +o nounset #disable strict mode
source "/root/.sdkman/bin/sdkman-init.sh"
set -o nounset #enable back strict mode

sleep 1h
echo "'mvn' version:"
mvn --version
echo "Logging to oc:"
sh ./oc_login.sh
source $SDKMAN_DIR/bin/sdkman-init.sh
echo "Executing tests:"
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


