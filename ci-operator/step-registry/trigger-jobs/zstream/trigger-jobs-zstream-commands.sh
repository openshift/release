#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

SECRETS_DIR=/run/secrets/ci.openshift.io/cluster-profile
API_TOKEN=$(cat $SECRETS_DIR/gangway-api-token)

WEEKLY_JOBS="$SECRETS_DIR/$JSON_TRIGGER_LIST"
#URL="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"

echo "# Printing the jobs tool version."
job --version

echo "# Checking the release controller for the latest stable zstream."
job get_payloads ${ZSTREAM_VERSION}

# Check if this Zstream version is new.
# If this Zstream version is new save it and then trigger the testing.

job run ${ZSTREAM_TRIGGER_JOB_NAME}

