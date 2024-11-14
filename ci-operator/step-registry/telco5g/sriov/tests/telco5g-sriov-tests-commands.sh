#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


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


[[ -f $SHARED_DIR/main.env ]] && source $SHARED_DIR/main.env || echo "No main.env file found"

# Set go version
if [[ "$T5CI_VERSION" == "4.12" ]] || [[ "$T5CI_VERSION" == "4.13" ]]; then
    source $HOME/golang-1.19
elif [[ "$T5CI_VERSION" == "4.14" ]] || [[ "$T5CI_VERSION" == "4.15" ]]; then
    source $HOME/golang-1.20
elif [[ "$T5CI_VERSION" == "4.16" ]]; then
    source $HOME/golang-1.21.11
else
    source $HOME/golang-1.22.4
fi

echo "Go version: $(go version)"

echo "******** Patching OperatorHub to disable all default sources"
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

echo "Wait for nodes to be up and ready"
# Wait for nodes to be ready
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait nodes --all --for=condition=Ready=true --timeout=10m

echo "Wait for cluster operators to be deployed and ready"
# Waiting for clusteroperators to finish progressing
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

set -x

export JUNIT_OUTPUT=$ARTIFACT_DIR

status=0

cd "$(mktemp -d)"

if [[ -n "$PULL_BASE_REF" ]]; then
    sriov_branch=$PULL_BASE_REF
else
    sriov_branch=master
fi

git clone --origin upstream --branch $sriov_branch https://github.com/openshift/sriov-network-operator sriov-network-operator
pushd sriov-network-operator

# Install Ginkgo tool
make ginkgo

if [[ -n "$PULL_NUMBER" ]] && [[ "$REPO_NAME" == "sriov-network-operator" ]] ; then
    git fetch upstream "pull/${PULL_NUMBER}/head"
    git checkout -b "pr-${PULL_NUMBER}" FETCH_HEAD
    BRANCH=$sriov_branch PR=$PULL_NUMBER hack/deploy-sriov-in-telco-ci.sh || status=$?
else
    BRANCH=$sriov_branch hack/deploy-sriov-in-telco-ci.sh || status=$?
fi

if [[ "$status" == "0" ]]; then
    hack/deploy-wait.sh || status=$?
    if [[ "$status" == "0" ]]; then
        SUITE=./test/conformance hack/run-e2e-conformance.sh || status=$?
    fi
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
[[ -f ${ARTIFACT_DIR}/unit_report.xml ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/unit_report.xml -o ${ARTIFACT_DIR}/test_results.html
[[ -f ${ARTIFACT_DIR}/unit_report.xml ]] && python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/unit_report.xml -o ${ARTIFACT_DIR}/test_results.json
[[ -f ${ARTIFACT_DIR}/unit_report.xml ]] && cp ${ARTIFACT_DIR}/unit_report.xml ${ARTIFACT_DIR}/junit.xml
[[ -f ${ARTIFACT_DIR}/test_results.html ]] && cp ${ARTIFACT_DIR}/test_results.html $ARTIFACT_DIR/test-summary.html

rm -rf ${SHARED_DIR}/myenv ${SHARED_DIR}/telco5gci
set +x
set -e

exit ${status}
