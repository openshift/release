#!/bin/bash

set -euo pipefail
go version

echo "Clone opencontainers distribution-spec Repository..."
cd /tmp && git clone https://github.com/opencontainers/distribution-spec.git && cd distribution-spec/conformance || true

# go test -c  && ls || true
go test -c -mod=mod  && ls || true

# Registry details
OCI_ROOT_URL=$(cat "$SHARED_DIR"/quayroute)
OCI_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
OCI_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
OCI_NAMESPACE="myconformanceorg/myrepo"
OCI_CROSSMOUNT_NAMESPACE="myconformanceorg/other"
OCI_REPORT_DIR=$ARTIFACT_DIR

export OCI_ROOT_URL
export OCI_USERNAME
export OCI_PASSWORD
export OCI_NAMESPACE
export OCI_CROSSMOUNT_NAMESPACE

# Which workflows to run
export OCI_TEST_PULL=1
export OCI_TEST_PUSH=1
export OCI_TEST_CONTENT_DISCOVERY=1
export OCI_TEST_CONTENT_MANAGEMENT=1

# Extra settings
export OCI_HIDE_SKIPPED_WORKFLOWS=0
export OCI_DEBUG=0
export OCI_DELETE_MANIFEST_BEFORE_BLOBS=0 # defaults to OCI_DELETE_MANIFEST_BEFORE_BLOBS=1 if not set

#Generate test result to ARTIFACT_DIR
export OCI_REPORT_DIR

echo "Start Quay OCI Conformance Testing"
./conformance.test || true
echo "Complete Quay OCI Conformance Testing"
