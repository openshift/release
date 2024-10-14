#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

cat /etc/os-release
oc config view
oc projects
python --version

pushd /tmp

git clone https://github.com/openshift/svt --depth=1
pushd svt

echo "========Start Regression test for $SCRIPT========"
set +e

# Do not change, for these custom tests we need to specify this specific version 
export KUBE_BURNER_VERSION='1.7.6'

# If SCRIPT is not specified, find the script by the TEST_CASE.
if [[ $SCRIPT == "" ]]
then
    SCRIPT=$(find perfscale_regression_ci -name $TEST_CASE.sh)
    if [[ $SCRIPT == "" ]]
    then
        echo "$TEST_CASE.sh is not found under svt repo perfscale_regression_ci/scripts folder. Please check."
        exit 1
    fi
fi
export folder=${SCRIPT%/*}
export script=${SCRIPT##*/} 
cd ${folder}

chmod +x ${script}
set -o pipefail
./${script} $PARAMETERS |& tee output.out

result=$?
set -e
# copy the reliability test result

cp output.out ${ARTIFACT_DIR}/
if [[ $result -ne 0 ]]; then
    exit 1
fi 