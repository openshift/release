#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


function create_tests_skip_list_file {
# List of test cases to ignore due to open bugs
cat <<EOF >"${SKIP_TESTS_FILE}"

# <feature> <test name>

# SKIPTEST
# bz### we can stop testing N3000
# TESTNAME
sriov "FPGA Programmable Acceleration Card N3000 for Networking"

# SKIPTEST
# bz### takes too much time
# TESTNAME
dpdk "Client should be able to forward packets"

EOF
}


function create_tests_temp_skip_list_11 {
# List of temporarly skipped tests for 4.11
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-8433
# TESTNAME

metallb "Correct and incorrect MetalLB resources coexist"

EOF
}


function create_tests_temp_skip_list_12 {
# List of temporarly skipped tests for 4.12
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-10424
# TESTNAME
performance "Should have the correct RPS configuration"

EOF
}

function create_tests_temp_skip_list_13 {
# List of temporarly skipped tests for 4.13
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-10424
# TESTNAME
performance "Check RPS Mask is applied to atleast one single rx queue on all veth interface"

EOF
}

function is_bm_node {
    node=$1

    machine=$(oc get "${node}" -o json | jq '.metadata.annotations' | grep "machine.openshift.io/machine" | cut -d ":" -f2 | tr -d '", ')
    machine_ns=$(echo "${machine}" | cut -d "/" -f1)
    machine_name=$(echo "${machine}" | cut -d "/" -f2)
    bmh=$(oc get machine -n "${machine_ns}" "${machine_name}" -o json | jq '.metadata.annotations' | grep "metal3.io/BareMetalHost" | cut -d ":" -f2 | tr -d '", ')
    bmh_ns=$(echo "${bmh}" | cut -d "/" -f1)
    bmh_name=$(echo "${bmh}" | cut -d "/" -f2)
    manufacturer=$(oc get bmh -n "${bmh_ns}" "${bmh_name}" -o json | jq '.status.hardware.systemVendor.manufacturer')
    # if the system manufacturer is not Red Hat, that's a BM node
    if [[ "${manufacturer}" != *"Red Hat"* ]]; then
        return 0
    fi
    return 1
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

source $SHARED_DIR/main.env

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy vrf bondcni tuningcni ptp}" # next: ovs_qos
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
cd -

# Skiplist common for all releases
create_tests_skip_list_file

# Skiplist according to each release
if [[ "$CNF_BRANCH" == *"4.11"* ]]; then
    create_tests_temp_skip_list_11
    export GINKGO_PARAMS='-ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.progress -ginkgo.reportPassed'

fi
if [[ "$CNF_BRANCH" == *"4.12"* ]]; then
    create_tests_temp_skip_list_12
    export GINKGO_PARAMS='-ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.progress -ginkgo.reportPassed'

fi
if [[ "$CNF_BRANCH" == *"4.13"* ]] || [[ "$CNF_BRANCH" == *"4.14"* ]] || [[ "$CNF_BRANCH" == *"master"* ]]; then
    create_tests_temp_skip_list_13
    export GINKGO_PARAMS='-ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.show-node-events'
fi
cp "$SKIP_TESTS_FILE" "${ARTIFACT_DIR}/"

export TESTS_REPORTS_PATH="${ARTIFACT_DIR}/"

skip_tests=$(get_skip_tests)

worker_nodes=$(oc get nodes --selector='node-role.kubernetes.io/worker' \
--selector='!node-role.kubernetes.io/master' -o name)
if [ -z "${worker_nodes}" ]; then
    echo "[ERROR]: No worker nodes found in cluster"
    exit 1
fi
# get BM workers for testing
test_nodes=""
for node in ${worker_nodes}; do
    if is_bm_node "${node}"; then
        test_nodes="${test_nodes} ${node}"
    fi
done

if [ -z "${test_nodes}" ]; then
    echo "[ERROR]: No BM worker nodes found in cluster"
    exit 1
fi

export CNF_NODES="${test_nodes}"

cd cnf-features-deploy
status=0
if [[ -n "$skip_tests" ]]; then
    export SKIP_TESTS="${skip_tests}"
fi
FEATURES_ENVIRONMENT="ci" make functests-on-ci || status=$?
cd -

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

junitparser merge ${ARTIFACT_DIR}/cnftests-junit*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/junit.xml

rm -rf ${SHARED_DIR}/myenv ${ARTIFACT_DIR}/setup_junit_*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/cnftests-junit_*xml
set -e

exit ${status}
