#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make functests-on-ci

export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export TESTS_REPORTS_PATH="${ARTIFACT_DIR}/"

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"CNF_BRANCH"* ]]; then
                CNF_BRANCH="$(echo "${var}" | cut -d'=' -f2)"
            fi
        fi
    done
fi

echo "running on branch ${CNF_BRANCH}"
git clone -b "${CNF_BRANCH}" "${CNF_REPO}" /tmp/cnf-features-deploy

export DONT_FOCUS=false

cd /tmp/cnf-features-deploy
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make setup-test-cluster
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make setup-build-index-image
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make feature-deploy
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make feature-wait
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make origin-tests
