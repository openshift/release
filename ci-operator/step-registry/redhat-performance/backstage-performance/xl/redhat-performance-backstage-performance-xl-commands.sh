#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

export OPENSHIFT_PASSWORD
export OPENSHIFT_API
export OPENSHIFT_USERNAME

echo -e "[INFO] Start tests"

echo "ENVIRONMENT:"
env | sort

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash <<-"EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
if [ $? -ne 0 ]; then
    echo "Timed out waiting for login"
    exit 1
fi

cd "$(mktemp -d)"
git clone --branch ${BACKSTAGE_PERFORMANCE_BASE_BRANCH:-main} https://github.com/redhat-performance/backstage-performance.git .

set -x
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]] && [ "$USE_PR_BRANCH" == "true" ]; then
    # if this is executed as PR check of github.com/redhat-performance/backstage-performance.git repo, switch to PR branch.
    git fetch origin "pull/${PULL_NUMBER}/head"
    git checkout -b "pr-${PULL_NUMBER}" FETCH_HEAD
fi
set +x

# Collect load test results at the end
trap './ci-scripts/collect-results.sh; trap EXIT' SIGINT EXIT

# Setup cluster
./ci-scripts/setup.sh

# Execute load test
./ci-scripts/test.sh
