#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


function reportToDataRouter() {
    if [[ $REPORT_TO_DR == "true" ]]; then
      datarouter-openshift-ci
    fi
}

export DATAROUTER_RESULTS="${SHARED_DIR}/*.xml"
export OCP_VERSION
export REPORTPORTAL_APPLY_TFA="${APPLY_TFA}"
export REPORTPORTAL_CMP
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop-dr_personal"
export REPORTPORTAL_LAUNCH_NAME="lp-interop-${OCP_VERSION}"

export DATAROUTER_METADATA_URL="https://raw.githubusercontent.com/CSPI-QE/cspi-utils/refs/heads/main/data-router/${OCP_VERSION}/metadata.json"

reportToDataRouter