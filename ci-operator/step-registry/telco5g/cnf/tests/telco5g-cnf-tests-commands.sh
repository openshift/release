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

EOF
}


function create_tests_temp_skip_list_11 {
# List of temporarly skipped tests for 4.11
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

EOF
}


function create_tests_temp_skip_list_12 {
# List of temporarly skipped tests for 4.12
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

EOF
}

function create_tests_temp_skip_list_13 {
# List of temporarly skipped tests for 4.13
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-10927
# TESTNAME
xt_u32 "Validate the module is enabled and works Should create an iptables rule inside a pod that has the module enabled"

EOF
}

function create_tests_temp_skip_list_14 {
# List of temporarly skipped tests for 4.14
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-10927
# TESTNAME
xt_u32 "Validate the module is enabled and works Should create an iptables rule inside a pod that has the module enabled"

EOF
}

function create_tests_temp_skip_list_15 {
# List of temporarly skipped tests for 4.15
cat <<EOF >>"${SKIP_TESTS_FILE}"
# <feature> <test name>

# SKIPTEST
# bz### https://issues.redhat.com/browse/OCPBUGS-10927
# TESTNAME
xt_u32 "Validate the module is enabled and works Should create an iptables rule inside a pod that has the module enabled"

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
        grep --text -E "^[^#]" "${SKIP_TESTS_FILE}" > ${SHARED_DIR}/feature_skip_list.txt
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
        done < ${SHARED_DIR}/feature_skip_list.txt
    fi

    echo "${skip_list}"
}

# Checkout the pull request branch
# $1 - github organization
# $2 - github repository
# $3 - pull request number
function checkout_pr_branch() {
    set -x
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    # Fetch the pull request branch
    git fetch --force origin --update-head-ok "pull/$pr_number/head:pr/$pr_number"
    # Check out the pull request branch
    git checkout "pr/$pr_number"
    git reset --hard HEAD
    set +x
}

# Check if we are running on a pull request and checkout the pull request branch
# $1 - github organization
# $2 - github repository
# PULL_URL - pull request URL the job is running on, from main.env file - calculated from CI environment variables
# PR_URLS - additional pull request URLs.
function check_for_pr() {
    set -x
    local org="$1"
    local repo="$2"
    # Check if current org and repo are in PULL_URL
    if [[ -n "${PULL_URL-}" && "${PULL_URL-}" == *"github.com/$org/$repo"* ]]; then
        # Extract the pull request number from the URL
        pr_number=$(echo "${PULL_URL-}" | cut -d'/' -f7)
        checkout_pr_branch "$org" "$repo" "$pr_number"
    # Check additional PRs from environment variable
    elif [[ -n "$PR_URLS" && "$PR_URLS" == *"github.com/$org/$repo"* ]]; then
        # Extract the pull request URL with org and repo from PR_URLS list
        TEST_CNF_TESTS_PR=$(echo "$PR_URLS" | grep -Eo "https://github.com/$org/$repo/\S+")
        # Remove the first and last quotes from the URL
        TEST_CNF_TESTS_PR=${TEST_CNF_TESTS_PR%\"}
        TEST_CNF_TESTS_PR=${TEST_CNF_TESTS_PR#\"}
        # Extract the pull request number from the URL
        pr_number=$(echo "$TEST_CNF_TESTS_PR" | cut -d'/' -f7)
        checkout_pr_branch "$org" "$repo" "$pr_number"
    else
        echo "The given pull request URL doesn't match the expected repository and organization: PULL_URL=${PULL_URL-}"
    fi
    set +x
    }

# Check if we are running on a pull request and check commit message for Depends-On
# If Depends-On is found, extract the pull request URL with org and repo from commit message
# For example: Depends-On: https://github.com/openshift-kni/cnf-features-deploy/pull/1394
function check_commit_message_for_prs {
    set -x
    EXTRACTED_PRS=""
    # Check if we in CI mode
    if [[ -n "${JOB_NAME-}" && -n "${PULL_URL-}" && "${JOB_NAME-}" == *"rehears"* ]]; then
        # Get the commit message from Github of current PR if exists
        API_PR_URL=$(echo "${PULL_URL-}" | sed "s@github.com@api.github.com/repos@" | sed "s/pull/pulls/")
        COMMIT_MESSAGE=$(curl -s "$API_PR_URL" | jq -r '.body')
        # Check if we have Depends-On: in commit message
        if [[ "$COMMIT_MESSAGE" == *"Depends-On:"* ]]; then
            # Extract the pull request URL with org and repo from commit message
            EXTRACTED_PRS=$(echo "$COMMIT_MESSAGE" | grep -oP 'Depends-On:\s*\S+' | sed "s/Depends-On:\s*//g" | xargs)
            if [[ $EXTRACTED_PRS == *"https"* ]]; then
                export PR_URLS="${PR_URLS} ${EXTRACTED_PRS}"
                # Trim spaces from PR_URLS
                export PR_URLS=${PR_URLS## }
            fi
        fi
    fi
}

function sno_fixes {
    echo "************ SNO fixes ************"
    pushd $CNF_REPO_DIR
    sed -i "s/role: worker-cnf/role: master/g" feature-configs/deploy/sctp/sctp_module_mc.yaml

    popd
}

function get_time_left {
    # Use it later for calculation of time left
    # Keep in mind the step starts after image preparation in cluster
    now=$(date +%s)
    then=$(cat $SHARED_DIR/start_time)
    minutes_passed=$(( (now - then) / 60 ))
    # the job has 4 hours to run, leave 10 minutes for reports etc
    time_left=$(( 215 - minutes_passed ))
    echo $time_left
}



[[ -f $SHARED_DIR/main.env ]] && source $SHARED_DIR/main.env || echo "No main.env file found"

# if set - to run tests and/or validations
export RUN_TESTS="${RUN_TESTS:-true}"
export RUN_VALIDATIONS="${RUN_VALIDATIONS:-true}"

if [[ "$T5CI_JOB_TYPE" == "sno-cnftests" ]]; then
    export FEATURES="${FEATURES:-performance sriov sctp}"
else
    export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy vrf bondcni tuningcni}"
fi
export VALIDATIONS_FEATURES="${VALIDATIONS_FEATURES:-$FEATURES}"
export TEST_RUN_FEATURES="${TEST_RUN_FEATURES:-$FEATURES}"

export SKIP_TESTS_FILE="${SKIP_TESTS_FILE:-${SHARED_DIR}/telco5g-cnf-tests-skip-list.txt}"
export SCTPTEST_HAS_NON_CNF_WORKERS="${SCTPTEST_HAS_NON_CNF_WORKERS:-false}"
export XT_U32TEST_HAS_NON_CNF_WORKERS="${XT_U32TEST_HAS_NON_CNF_WORKERS:-false}"

export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"
# List of PRs to test
export PR_URLS="${PR_URLS:-}"
check_commit_message_for_prs || true  # Ignore errors, we don't want to fail the job if we can't get the commit message

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

if [[ "$T5CI_VERSION" == "4.15" ]]; then
    export CNF_BRANCH="master"
    export CNF_TESTS_IMAGE="cnf-tests:4.14"
else
    export CNF_BRANCH="release-${T5CI_VERSION}"
    export CNF_TESTS_IMAGE="cnf-tests:${T5CI_VERSION}"
fi

CNF_REPO_DIR=${CNF_REPO_DIR:-"$(mktemp -d -t cnf-XXXXX)/cnf-features-deploy"}

# Check if cnf-features-deploy repository exists
# If not, clone it
if [[ ! -d "${CNF_REPO_DIR}" ]]; then
    echo "cnf-features-deploy repository not found, cloning it to ${CNF_REPO_DIR}"
    mkdir -p "$CNF_REPO_DIR"
    echo "running on branch ${CNF_BRANCH}"
    git clone -b "${CNF_BRANCH}" "${CNF_REPO}" $CNF_REPO_DIR
fi

pushd $CNF_REPO_DIR
if [[ "$T5CI_VERSION" == "4.15" ]]; then
    echo "Updating all submodules for >=4.15 versions"
    # git version 1.8 doesn't work well with forked repositories, requires a specific branch to be set
    sed -i "s@https://github.com/openshift/metallb-operator.git@https://github.com/openshift/metallb-operator.git\n        branch = main@" .gitmodules
    git submodule update --init --force --recursive --remote
    git submodule foreach --recursive 'echo $path `git config --get remote.origin.url` `git rev-parse HEAD`' | grep -v Entering > ${ARTIFACT_DIR}/hashes.txt || true
fi
echo "******** Checking out pull request for repository cnf-features-deploy if exists"
check_for_pr "openshift-kni" "cnf-features-deploy"
popd

echo "******** Patching OperatorHub to disable all default sources"
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

# Skiplist common for all releases
create_tests_skip_list_file

# Skiplist according to each release and add flakey parameter for Ginkgo v1 and v2
if [[ "$CNF_BRANCH" == *"4.11"* ]]; then
    create_tests_temp_skip_list_11
    export GINKGO_PARAMS="-ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.progress -ginkgo.reportPassed -ginkgo.flakeAttempts 4"

fi
if [[ "$CNF_BRANCH" == *"4.12"* ]]; then
    create_tests_temp_skip_list_12
    export GINKGO_PARAMS="-ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.progress -ginkgo.reportPassed -ginkgo.flakeAttempts 4"

fi
if [[ "$CNF_BRANCH" == *"4.13"* ]]; then
    create_tests_temp_skip_list_13
    export GINKGO_PARAMS=" --ginkgo.timeout 230m -ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.show-node-events --ginkgo.json-report ${ARTIFACT_DIR}/test_ginkgo.json --ginkgo.flake-attempts 4"
fi
if [[ "$CNF_BRANCH" == *"4.14"* ]]; then
    create_tests_temp_skip_list_14
    export GINKGO_PARAMS=" --ginkgo.timeout 230m -ginkgo.slowSpecThreshold=0.001 -ginkgo.v -ginkgo.show-node-events --ginkgo.json-report ${ARTIFACT_DIR}/test_ginkgo.json --ginkgo.flake-attempts 4"
fi
if [[ "$CNF_BRANCH" == *"4.15"* ]] || [[ "$CNF_BRANCH" == *"master"* ]]; then
    create_tests_temp_skip_list_15
    export GINKGO_PARAMS=" --timeout 230m -slow-spec-threshold=0.001s -v --show-node-events --json-report test_ginkgo.json --flake-attempts 4"
fi
cp "$SKIP_TESTS_FILE" "${ARTIFACT_DIR}/"

export TESTS_REPORTS_PATH="${ARTIFACT_DIR}/"

skip_tests=$(get_skip_tests)

if [[ "$T5CI_JOB_TYPE" != "sno-cnftests" ]]; then
    echo "******** For non-SNO jobs, get worker nodes"
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
fi

if [[ "$T5CI_JOB_TYPE" == "sno-cnftests" ]]; then
    echo "******** For SNO jobs, get master nodes"
    test_nodes=$(oc get nodes --selector='node-role.kubernetes.io/worker' -o name)
    export ROLE_WORKER_CNF="master"
    # Make local workarounds for SNO
    echo "******** Running SNO fixes"
    sno_fixes
fi
export CNF_NODES="${test_nodes}"

pushd $CNF_REPO_DIR
status=0
val_status=0

if [[ -n "$skip_tests" ]]; then
    export SKIP_TESTS="${skip_tests}"
fi
# if RUN_VALIDATIONS set, run validations
if $RUN_VALIDATIONS; then
    echo "************ Running validations ************"
    FEATURES=$VALIDATIONS_FEATURES FEATURES_ENVIRONMENT="ci" stdbuf -o0 make feature-deploy-on-ci 2>&1 | tee ${SHARED_DIR}/cnf-validations-run.log ${ARTIFACT_DIR}/saved-cnf-validations.log || val_status=$?
fi
# set overall status to fail if validations failed
if [[ ${val_status} -ne 0 ]]; then
    echo "Validations failed with status code $val_status"
    status=${val_status}
fi

echo "Wait until number of nodes matches number of machines"
# Wait until number of nodes matches number of machines
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
for _ in $(seq 30); do
    nodes="$(oc get nodes --no-headers | wc -l)"
    machines="$(oc get machines -A --no-headers | wc -l)"
    [ "$machines" -le "$nodes" ] && break
    sleep 30
done

echo "Check if nodes amount '$nodes' equal to machines '$machines'"
[ "$machines" -le "$nodes" ]

echo "Wait for nodes to be up and ready"
# Wait for nodes to be ready
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait nodes --all --for=condition=Ready=true --timeout=10m

echo "Wait for cluster operators to be deployed and ready"
# Waiting for clusteroperators to finish progressing
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

# if validations passed and RUN_TESTS set, run the tests
if [[ ${val_status} -eq 0 ]] && $RUN_TESTS; then
    echo "************ Running e2e tests ************"
    FEATURES=$TEST_RUN_FEATURES FEATURES_ENVIRONMENT="ci" stdbuf -o0 make functests 2>&1 | tee ${SHARED_DIR}/cnf-tests-run.log ${ARTIFACT_DIR}/saved-cnf-tests-run.log || status=$?
fi
popd

set +e
set -x
python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci ${SHARED_DIR}/telco5gci

# Check if telco5gci pull request exists and checkout the pull request branch if so
pushd ${SHARED_DIR}/telco5gci
check_for_pr "openshift-kni" "telco5gci"
popd

pip install -r ${SHARED_DIR}/telco5gci/requirements.txt
# Create HTML reports for humans/aliens
[[ -f ${ARTIFACT_DIR}/cnftests-junit.xml ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/cnftests-junit.xml -o ${ARTIFACT_DIR}/test_results.html
ls ${ARTIFACT_DIR}/validation_junit*xml && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.html
[[ -f ${ARTIFACT_DIR}/setup_junit.xml ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/setup_junit.xml -o ${ARTIFACT_DIR}/setup_results.html
# Run validation parser
[[ -f ${SHARED_DIR}/cnf-validations-run.log ]] && python ${SHARED_DIR}/telco5gci/parse_log.py --test-type validations --path ${SHARED_DIR}/cnf-validations-run.log --output-file ${ARTIFACT_DIR}/parsed-validations.json
[[ -f ${ARTIFACT_DIR}/parsed-validations.json ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/parsed-validations.json -f json -o ${ARTIFACT_DIR}/parsed_validations.html
# Create JSON reports for robots
[[ -f ${ARTIFACT_DIR}/cnftests-junit.xml ]] && python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/cnftests-junit.xml -o ${ARTIFACT_DIR}/test_results.json
[[ -f ${ARTIFACT_DIR}/validation_junit.xml ]] && python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/validation_junit.xml -o ${ARTIFACT_DIR}/validation_results.json
[[ -f ${ARTIFACT_DIR}/setup_junit.xml ]] && python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/setup_junit.xml -o ${ARTIFACT_DIR}/setup_results.json

junitparser merge ${ARTIFACT_DIR}/cnftests-junit*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/junit.xml

rm -rf ${SHARED_DIR}/myenv ${SHARED_DIR}/telco5gci
set +x
set -e

exit ${status}
