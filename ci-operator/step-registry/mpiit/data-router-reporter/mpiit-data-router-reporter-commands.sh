#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

sleep 3h

export DATAROUTER_RESULTS="${SHARED_DIR}/*.xml"
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop-dr_personal"
export OCP_VERSION
export REPORTPORTAL_LAUNCH_NAME="lp-interop-${OCP_VERSION}"
export REPORTPORTAL_APPLY_TFA="${AAPLY_TFA}"
export REPORTPORTAL_CMP

export REPORTPORTAL_LAUNCH_ATTRIBUTES="[
  {\"key\": \"version\", \"value\": \"${OCP_VERSION}\"},
  {\"key\": \"environment\", \"value\": \"prod\"},
  {\"key\": \"component\", \"value\": \"${REPORTPORTAL_CMP}\"},
  {\"key\": \"team\", \"value\": \"mpiit\"}
]"
export DATAROUTER_METADATA_URL="https://raw.githubusercontent.com/oharan2/cspi-utils/8fadc6dde0d67f549dfea0acd8356b8184aac99a/data-router/metadata.json"

datarouter-openshift-ci
