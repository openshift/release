#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

status=0

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

for JDK_VER in $OPENJDK_VERSION
do
    status1=0
    mkdir -p $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

	# Run tests
	echo "Executing tests for Open JDK $JDK_VER..."
	./run.sh --jdk-version=$JDK_VER || status1="$?" || :

    if [ "$status1" -ne "0" ]
    then
        status="$status1"
    fi

	# Copy results and artifacts to $ARTIFACT_DIR
	echo "Archiving logs for Open JDK $JDK_VER..."
	cp ./test-openjdk/log/* $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

	echo "Archiving results for Open JDK $JDK_VER..."
	cp -r ./test-openjdk/target/surefire-reports  $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

    # Rename result xml files
    NAME=/junit_jdk${JDK_VER}_TEST- || :
    rename '/TEST-' $NAME ${ARTIFACT_DIR}/test-run-results/openjdk-$JDK_VER/surefire-reports/TEST-*.xml 2>/dev/null || :
done

exit $status

