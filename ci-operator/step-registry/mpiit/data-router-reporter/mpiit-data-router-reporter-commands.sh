#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export OCP_VERSION
export DATAROUTER_RESULTS="${SHARED_DIR}/results/*.xml"
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop"
export REPORTPORTAL_LAUNCH_NAME="lp-interop-${OCP_VERSION}"
export REPORTPORTAL_APPLY_TFA="${AAPLY_TFA}"
export REPORTPORTAL_CMP

export REPORTPORTAL_LAUNCH_ATTRIBUTES="[
  {\"key\": \"version\", \"value\": \"${OCP_VERSION}\"},
  {\"key\": \"environment\", \"value\": \"staging\"},
  {\"key\": \"component\", \"value\": \"${REPORTPORTAL_CMP}\"},
  {\"key\": \"team\", \"value\": \"mpiit\"}
]"
datarouter-openshift-ci
