#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

export OPENSHIFT_PASSWORD
export BYOC_KUBECONFIG

export OPENSHIFT_API
export OPENSHIFT_USERNAME

echo -e "[INFO] Start tests"

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

# Define a new environment for BYOC pointing to a kubeconfig with token. RHTAP environments only supports kubeconfig with token:
# See: https://issues.redhat.com/browse/GITOPSRVCE-554
BYOC_KUBECONFIG="/tmp/token-kubeconfig"
cp "$KUBECONFIG" "$BYOC_KUBECONFIG"
if [[ -s "$BYOC_KUBECONFIG" ]]; then
    echo -e "byoc kubeconfig exists!"
else
    echo "Kubeconfig not exists in $BYOC_KUBECONFIG... Aborting job"
    exit 1
fi

export AWS_ACCESS_ID AWS_BUCKET_NAME AWS_SECRET_KEY AWS_ENDPOINT AWS_REGION

AWS_REGION="eu-west-1"
AWS_ENDPOINT="https://s3.eu-west-1.amazonaws.com"
AWS_ACCESS_ID="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-access-id )"
AWS_BUCKET_NAME="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-bucket-name )"
AWS_SECRET_KEY="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-secret-key )"

cd "$(mktemp -d)"
git clone --branch main https://github.com/openshift-pipelines/performance.git .

# If this is a PR check of the performance repo (not rehearse job), switch to PR branch
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    echo "[INFO] Presubmit job detected - switching to PR #${PULL_NUMBER}"
    git fetch origin "pull/${PULL_NUMBER}/head"
    git checkout -b "pr-${PULL_NUMBER}" FETCH_HEAD
fi

# Setup Tekton cluster
./ci-scripts/setup-cluster.sh

if [[ -n "${TEST_SCENARIOS:-}" ]]; then
    # Multi-scenario mode: run multiple parameter combinations on the same cluster.
    # Format: "total/concurrent/namespace/steps" (space-separated list)

    cleanup_namespaces() {
        for ns_idx in $(seq 1 "${TEST_NAMESPACE}"); do
            ns_tag=$([ "$TEST_NAMESPACE" -eq 1 ] && echo "" || echo "$ns_idx")
            oc delete --cascade=foreground --timeout=30m namespace "benchmark${ns_tag}" 2>/dev/null || true
        done
    }

    overall_rc=0
    for scenario in $TEST_SCENARIOS; do
        IFS='/' read -r t c n s <<< "$scenario"
        if [[ -z "$t" || -z "$c" || -z "$n" || -z "$s" ]]; then
            echo "[ERROR] Malformed scenario '$scenario': expected total/concurrent/namespace/steps"
            exit 1
        fi
        export TEST_TOTAL="$t"
        export TEST_CONCURRENT="$c"
        export TEST_NAMESPACE="$n"
        export TEST_BIGBANG_MULTI_STEP__STEP_COUNT="$s"

        echo "[INFO] Scenario: total=$TEST_TOTAL concurrent=$TEST_CONCURRENT ns=$TEST_NAMESPACE steps=$TEST_BIGBANG_MULTI_STEP__STEP_COUNT"

        run_artifacts="${ARTIFACT_DIR:-artifacts}/run-${TEST_TOTAL}-${TEST_CONCURRENT}-${TEST_NAMESPACE}-${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}"
        mkdir -p "$run_artifacts"

        rm -f tests/scaling-pipelines/benchmark-tekton.json
        rm -f tests/scaling-pipelines/benchmark-stats.csv
        rm -f tests/scaling-pipelines/cluster-benchmark-stats.csv
        rm -f tests/scaling-pipelines/benchmark-output.json
        rm -f tests/scaling-pipelines/pipelineruns-stats.csv
        rm -f tests/scaling-pipelines/taskruns-stats.csv

        scenario_rc=0
        ./ci-scripts/load-test.sh || scenario_rc=$?
        ARTIFACT_DIR="$run_artifacts" ./ci-scripts/collect-results.sh || true

        cleanup_namespaces
        sleep 60

        if (( scenario_rc != 0 )); then
            echo "[WARN] Scenario $scenario failed (rc=$scenario_rc), continuing..."
            overall_rc=1
        fi
    done
    exit "$overall_rc"
else
    # Single-scenario mode: existing behavior
    trap './ci-scripts/collect-results.sh; trap EXIT' SIGINT EXIT
    ./ci-scripts/load-test.sh
fi
