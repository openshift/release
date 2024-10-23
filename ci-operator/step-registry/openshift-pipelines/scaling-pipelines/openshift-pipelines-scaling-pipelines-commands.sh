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

export AWS_ACCESS_ID AWS_BUCKET_NAME AWS_SECRET_KEY

ls -l /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/

AWS_ACCESS_ID="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-access-id )"
AWS_BUCKET_NAME="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-bucket-name )"
AWS_SECRET_KEY="$( cat /usr/local/ci-secrets/openshift-pipelines-scaling-pipelines/aws-secret-key )"

cd "$(mktemp -d)"
git clone --branch main https://github.com/openshift-pipelines/performance.git .

# Collect load test results at the end
trap './ci-scripts/collect-results.sh; trap EXIT' SIGINT EXIT

# Setup Tekton cluster
./ci-scripts/setup-cluster.sh

# Execute load test
./ci-scripts/load-test.sh
