#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

sleep 1h

export OCP_VERSION
export DATAROUTER_RESULTS="${SHARED_DIR}/results/*.xml"
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop"
export REPORTPORTAL_LAUNCH_NAME="lp-interop-${OCP_VERSION}"
export REPORTPORTAL_APPLY_TFA="${AAPLY_TFA}"
export REPORTPORTAL_CMP

export REPORTPORTAL_LAUNCH_ATTRIBUTES="[
  {\"key\": \"version\", \"value\": \"${OCP_VERSION}\"},
  {\"key\": \"environment\", \"value\": \"prod\"},
  {\"key\": \"component\", \"value\": \"${REPORTPORTAL_CMP}\"},
  {\"key\": \"team\", \"value\": \"mpiit\"}
]"
export DATAROUTER_METADATA_URL="https://raw.githubusercontent.com/openshift/release/1bf8eeea33187be897d912cb7149602461cf5975/ci-operator/step-registry/mpiit/data-router-reporter/metadata.json"

datarouter-openshift-ci
