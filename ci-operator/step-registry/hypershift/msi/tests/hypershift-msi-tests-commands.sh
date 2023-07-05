#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

export OCM_TOKEN=${OCM_TOKEN}

AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
KEY_ID=$(cut -d"=" -f2 <<< "$(grep aws_access_key_id "${AWS_CREDS}")")
ACCESS_KEY=$(cut -d"=" -f2 <<< "$(grep aws_secret_access_key "${AWS_CREDS}")")
export AWS_ACCESS_KEY_ID=$KEY_ID
export AWS_SECRET_ACCESS_KEY=$ACCESS_KEY

poetry run pytest tests \
  -o log_cli=true \
  --junit-xml="${ARTIFACT_DIR}/xunit_results.xml" \
  --pytest-log-file="${ARTIFACT_DIR}/pytest-tests.log" \
  --ocp-target-version "${HYPERSHIFT_VERSION}" \
  -m hypershift_install  \
  --tc=api_server:"${API_HOST}" \
  --tc=openshift_channel_group:"${CHANNEL_GROUP}" \
  --tc=home_dir:/tmp \
  --tc=aws_region:"${AWS_REGION}" \
  --tc=aws_compute_machine_type:"${COMPUTE_MACHINE_TYPE}" \
  --tc=rosa_number_of_nodes:"${REPLICAS}"
