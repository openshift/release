#!/bin/bash

set -u
set -e
set -o pipefail

URL=$(oc whoami --show-server)
export URL

export ADMIN_PASSWORD="admin"

export ADMIN_USERNAME="admin"

export NAMESPACE="fuse-online"

echo "seluserlp:x:$(id -u):$(id -g):seluserlp:/home/seluser:/bin/bash" >> /etc/passwd
echo "seluserlp:x:$(id -G | cut -d' ' -f 2):" >> /etc/group

status=0

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

/home/seluser/entrypoint.sh || status="$?" || :

mkdir -p $ARTIFACT_DIR/test-run-results

# Copy results to ARTIFACT_DIR
while read -r FILE; do mkdir -p $ARTIFACT_DIR/test-run-results/"$(dirname "$FILE")"; cp "$FILE" $ARTIFACT_DIR/test-run-results/"$(dirname "$FILE")"; done <<< "$(find * -type f -name "*.log")"

while read -r DIR; do mkdir -p $ARTIFACT_DIR/test-run-results/"$DIR"; cp -r "$DIR"/* $ARTIFACT_DIR/test-run-results/"$DIR"; done <<< "$(find * -maxdepth 2 -type d -wholename "*target/cucumber*")"

# Prepend junit_ to result xml files
mv ${ARTIFACT_DIR}/test-run-results/rest-tests/target/cucumber/cucumber-junit.xml ${ARTIFACT_DIR}/test-run-results/rest-tests/target/cucumber/junit_rest-cucumber-junit.xml
mv ${ARTIFACT_DIR}/test-run-results/ui-tests/target/cucumber/cucumber-junit.xml ${ARTIFACT_DIR}/test-run-results/ui-tests/target/cucumber/junit_ui-cucumber-junit.xml

pkill Xvfb -u seluserlp || :

exit $status

