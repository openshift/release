#!/bin/bash

# gcloud authentication
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --quiet --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
gcloud config set project "${GOOGLE_PROJECT_ID}"

echo "Enabling Secret Manager API"
gcloud services enable secretmanager.googleapis.com --quiet

# Run gcp end-to-end tests
make e2e-gcp
