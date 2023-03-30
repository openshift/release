#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $SHARED_DIR/main.env

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy}" # next: ovs_qos
export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"CNF_E2E_TESTS"* ]]; then
                CNF_E2E_TESTS="$(echo "${var}" | cut -d'=' -f2)"
            elif [[ "${var}" == *"CNF_ORIGIN_TESTS"* ]]; then
                CNF_ORIGIN_TESTS="$(echo "${var}" | cut -d'=' -f2)"
            fi
        fi
    done
fi

export CNF_E2E_TESTS
export CNF_ORIGIN_TESTS

if [[ "$T5CI_VERSION" == "4.14" ]]; then
    export CNF_BRANCH="master"
else
    export CNF_BRANCH="release-${T5CI_VERSION}"
fi

cnf_dir=$(mktemp -d -t cnf-XXXXX)
cd "$cnf_dir" || exit 1

echo "running on branch ${CNF_BRANCH}"
git clone -b "${CNF_BRANCH}" "${CNF_REPO}" cnf-features-deploy
cd cnf-features-deploy
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

status=0
FEATURES_ENVIRONMENT="ci" make feature-deploy-on-ci || status=$?
cd -


set +e
python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci ${SHARED_DIR}/telco5gci
pip install -r ${SHARED_DIR}/telco5gci/requirements.txt
# Create HTML reports for humans/aliens
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.html
# Create JSON reports for robots
python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.json

junitparser merge ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/junit.xml

rm -rf ${SHARED_DIR}/myenv ${ARTIFACT_DIR}/setup_junit_*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/cnftests-junit_*xml
set -e

exit ${status}
