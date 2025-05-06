#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_PROFILE_DIR="/run/secrets/ci.openshift.io/cluster-profile"
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json

GOOGLE_COMPUTE_ZONE="us-central1-f"
GOOGLE_COMPUTE_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
VM_NAME="prow-e2e-vm-${PROW_JOB_ID}"

echo "Executing e2e tests on GCP VM: $VM_NAME"
gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command='
set -eux
cd instaslice-operator
# run e2e tests
IMG=quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-controller:$PULL_PULL_SHA IMG_DMST=quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-daemonset:$PULL_PULL_SHA make deploy
ginkgo -v --json-report=report.json --junit-report=report.xml --timeout 20m ./test/e2e
'