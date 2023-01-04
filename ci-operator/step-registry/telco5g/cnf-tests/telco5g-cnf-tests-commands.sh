#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


function create_tests_skip_list_file {
# List of test cases to ignore due to open bugs
cat <<EOF >"${SKIP_TESTS_FILE}"

# <feature> <test name>

# this test is checking that there are no none cnf-worker nodes with rt kernel enabled.
# when running cnf-tests in parallel we do have other nodes with rt kernel so the test is failing.
performance "a node without performance profile applied should not have RT kernel installed"

# need to investigate why it's failing
sriov "Test Connectivity Connectivity between client and server Should work over a SR-IOV device"

# this test needs both sriov and sctp available in the cluster.
# since we run them in parallel we can't run this test.
sriov "Allow access only to a specific port/protocol SCTP"

# this test needs both sriov and sctp available in the cluster.
# since we run them in parallel we can't run this test.
sctp "Allow access only to a specific port/protocol SCTP"

EOF
}


function create_tests_temp_skip_list_11 {
# List of temporarly skipped tests for 4.11
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### this test can't run in parallel with SRIOV/VRF tests and fails often
# TESTNAME
sriov "2 Pods 2 VRFs OCP Primary network overlap {\\\"IPStack\\\":\\\"ipv4\\\"}"
EOF
}


function create_tests_temp_skip_list_12 {
# List of temporarly skipped tests for 4.12
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### known bug
# TESTNAME
sriov "Should be able to configure a metaplugin"

# SKIPTEST
# bz### known bug
# TESTNAME
sriov "Webhook resource injector"

# SKIPTEST
# bz### known bug
# TESTNAME
sriov "pod with sysctl\\\'s on bond over sriov interfaces should start"

# SKIPTEST
# PR https://github.com/openshift-kni/cnf-features-deploy/pull/1302
# TESTNAME
performance "should disable CPU load balancing for CPU\\\'s used by the pod"

# SKIPTEST
# PR https://github.com/openshift-kni/cnf-features-deploy/pull/1302
# TESTNAME
performance "should run infra containers on reserved CPUs"

# SKIPTEST
# PR https://github.com/openshift-kni/cnf-features-deploy/pull/1302
# TESTNAME
performance "Huge pages support for container workloads"

# SKIPTEST
# bz### this test can't run in parallel with SRIOV/VRF tests and fails often
# TESTNAME
sriov "2 Pods 2 VRFs OCP Primary network overlap {\\\"IPStack\\\":\\\"ipv4\\\"}"

# SKIPTEST
# bz### https://issues.redhat.com/browse/CNF-6862
# TESTNAME
performance "Checking IRQBalance settings Verify irqbalance configuration handling Should not overwrite the banned CPU set on tuned restart"

# SKIPTEST
# bz### https://issues.redhat.com/browse/CNF-6862
# TESTNAME
performance "Checking IRQBalance settings Verify irqbalance configuration handling Should store empty cpu mask in the backup"

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-4194
# TESTNAME
performance "Should have the correct RPS configuration"

EOF
}

function create_tests_temp_skip_list_13 {
    create_tests_temp_skip_list_12
}


function create_ns {
    ns=$1

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
---
EOF
}

function get_skip_tests {

    skip_list=""
    if [ -f "${SKIP_TESTS_FILE}" ]; then
        rm -f feature_skip_list.txt
        grep --text -E "^[^#]" "${SKIP_TESTS_FILE}" > feature_skip_list.txt
        skip_list=""
        while read line;
        do
            test=$(echo "${line}" | cut -d " " -f2- | tr " " .)
            if [ ! -z "${test}" ]; then
                if [ "${skip_list}" == "" ]; then
                    skip_list="${test}"
                else
                    skip_list="${skip_list} ${test}"
                fi
            fi
        done < feature_skip_list.txt
    fi

    echo "${skip_list}"
}

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy}" # next: ovs_qos
export SKIP_TESTS_FILE="${SKIP_TESTS_FILE:-${SHARED_DIR}/telco5g-cnf-tests-skip-list.txt}"
export SCTPTEST_HAS_NON_CNF_WORKERS="${SCTPTEST_HAS_NON_CNF_WORKERS:-false}"
export XT_U32TEST_HAS_NON_CNF_WORKERS="${XT_U32TEST_HAS_NON_CNF_WORKERS:-false}"

export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"T5CI_VERSION"* ]]; then
                T5CI_VERSION="$(echo "${var}" | cut -d'=' -f2)"
            fi
        fi
    done
fi

if [[ "$T5CI_VERSION" == "4.13" ]]; then
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
# make setup-build-index-image
cd -

# Skiplist common for all releases
create_tests_skip_list_file

# Skiplist according to each release
if [[ "$CNF_BRANCH" == *"4.11"* ]]; then
    create_tests_temp_skip_list_11
fi
if [[ "$CNF_BRANCH" == *"4.12"* ]] || [[ "$CNF_BRANCH" == *"master"* ]]; then
    create_tests_temp_skip_list_12
fi
if [[ "$CNF_BRANCH" == *"4.13"* ]]; then
    create_tests_temp_skip_list_13
fi
cp "$SKIP_TESTS_FILE" "${ARTIFACT_DIR}/"

export ROLE_WORKER_CNF="worker-cnf"
export TESTS_REPORTS_PATH="${ARTIFACT_DIR}/"

skip_tests=$(get_skip_tests)

cd cnf-features-deploy
status=0
# SKIP_TESTS="${skip_tests}"
FEATURES_ENVIRONMENT="ci" FEATURES="sriov performance sctp xt_u32 ovn metallb multinetworkpolicy" make functests-on-ci || status=$?
# FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance" make feature-deploy
# FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance" make feature-wait
cd -


# Create a HTML report
# for feature in ${FEATURES}; do
#     xml_f="${ARTIFACT_DIR}/${feature}/cnftests-junit.xml"
#     if [[ -f $xml_f ]]; then
#         cp $xml_f ${ARTIFACT_DIR}/cnftests-junit_${feature}.xml
#     fi
#     xml_v="${ARTIFACT_DIR}/${feature}/validation_junit.xml"
#     if [[ -f $xml_v ]]; then
#         cp $xml_v ${ARTIFACT_DIR}/validation_junit_${feature}.xml
#     fi
#     xml_s="${ARTIFACT_DIR}/${feature}/setup_junit.xml"
#     if [[ -f $xml_s ]]; then
#         cp $xml_s ${ARTIFACT_DIR}/setup_junit_${feature}.xml
#     fi
# done
set +e

python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci ${SHARED_DIR}/telco5gci
pip install -r ${SHARED_DIR}/telco5gci/requirements.txt
# Create HTML reports for humans/aliens
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/cnftests-junit*xml -o ${ARTIFACT_DIR}/test_results.html
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.html
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/setup_junit_*xml -o ${ARTIFACT_DIR}/setup_results.html
# Create JSON reports for robots
python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/cnftests-junit*xml -o ${ARTIFACT_DIR}/test_results.json
python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.json
python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/setup_junit_*xml -o ${ARTIFACT_DIR}/setup_results.json

# Create a merged report for all features to use in Prow page
junitparser merge ${ARTIFACT_DIR}/validation_junit.xml ${ARTIFACT_DIR}/cnftests-junit.xml ${ARTIFACT_DIR}/junit.xml

#rm -rf ${SHARED_DIR}/myenv ${ARTIFACT_DIR}/setup_junit_*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/cnftests-junit_*xml
set -e

exit ${status}
