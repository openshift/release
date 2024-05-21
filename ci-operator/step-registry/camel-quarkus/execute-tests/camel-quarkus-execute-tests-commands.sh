#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Collect test reports into $ARTIFACT_DIR
PROJECTS=$PROJECTS

function collect-results() {
    echo "Copying results and xmls to ${ARTIFACT_DIR}"
    for PROJECT in ${PROJECTS//","/" "}; do
      for FILE in ./$PROJECT/target/failsafe-reports/TEST-*.xml; do
        FILENAME=$(basename $FILE)
        if [[ -f "${FILE}" ]]; then
            TARGET=${ARTIFACT_DIR}/junit_${FILENAME}
            echo "Collecting ${TARGET}"
            cp $FILE $TARGET
        fi
      done
    done
}

echo "heya"
echo "Logging to oc:"
sh ./oc_login.sh
echo "Executing tests:"
trap collect-results SIGINT SIGTERM ERR EXIT
sh ./run.sh




