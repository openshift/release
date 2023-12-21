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

echo "[INFO] Start tests"

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
    echo "byoc kubeconfig exists!"
else
    echo "Kubeconfig not exists in $BYOC_KUBECONFIG... Aborting job"
    exit 1
fi

cd "$(mktemp -d)"
git clone --branch master https://github.com/openshift-pipelines/performance.git .

# Setup Tekton cluster
./ci-scripts/setup-cluster.sh

# Warm up
export TEST_DO_CLEANUP=false
export TEST_TOTAL=20
export TEST_CONCURRENT=10
ci-scripts/load-test.sh
oc delete namespace/benchmark
sleep 60

for scenario in $TEST_SCENARIOS; do
    TEST_TOTAL="$( echo "$scenario" | cut -d "/" -f 1 )"
    TEST_CONCURRENT="$( echo "$scenario" | cut -d "/" -f 2 )"
    artifacts="${ARTIFACT_DIR:-artifacts}/run-$TEST_TOTAL-$TEST_CONCURRENT"
    mkdir -p "$ARTIFACT_DIR"
    rm -f tests/scaling-pipelines/benchmark-tekton.json
    ci-scripts/load-test.sh
    ARTIFACT_DIR="$artifacts" ci-scripts/collect-results.sh
    oc -n benchmark get pods -o json >"$artifacts/pods.json"
    oc -n benchmark get taskruns -o json >"$artifacts/taskruns.json"
    oc -n benchmark get pipelineruns -o json >"$artifacts/pipelineruns.json"
    if ! oc delete --cascade=foreground --timeout=30m namespace/benchmark; then
        echo "[WARNING] Namespace benchmark failed, ignoring it"
    fi
    sleep 60
done
