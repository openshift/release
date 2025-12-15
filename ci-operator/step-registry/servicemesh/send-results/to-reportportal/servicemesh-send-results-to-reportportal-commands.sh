#!/bin/bash

set -eo pipefail

get_job_url() {
  local job_base_url="https://prow.ci.openshift.org/view/gs/test-platform-results"
  local job_complete_url
  if [ -n "${PULL_NUMBER:-}" ]; then
    job_complete_url="${job_base_url}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
  else
    job_complete_url="${job_base_url}/logs/${JOB_NAME}/${BUILD_ID}"
  fi
  echo "${job_complete_url}"
}

# run the upload only if explicitly configured
if [ "${REPORT_TO_REPORT_PORTAL}" != "true" ]
then
  echo "REPORT_TO_REPORT_PORTAL is disabled. Results will not be uploaded."
  exit 0
fi

# get ocp info and product version from JOB_NAME
# TODO: improve this to still get the info dynamically but without relying on JOB_NAME
ocp_arch="unknown"
# we currently only use two architectures
if [[ "$JOB_NAME" =~ arm ]]
then
  ocp_arch="arm"
else
  ocp_arch="x86_64"
fi

ocp_version="unknown"
if [[ "$JOB_NAME" =~ ocp-(4[.][0-9]+)- ]]
then
  version="${BASH_REMATCH[1]}"
  if [[ -n "$version" ]]
  then
    ocp_version="$version"
  fi
fi

product_version="unknown"
if [[ "$JOB_NAME" =~ main|master ]]
then
  product_version="main"
elif [[ "$JOB_NAME" =~ release-(3[.][0-9]+)- ]]
then
  version="${BASH_REMATCH[1]}"
  if [[ -n "$version" ]]
  then
    product_version="$version"
  fi
fi

# Download and source the script from ci-utils
REPORTING_SCRIPT_URL="https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/refs/heads/main/report_portal/send_report_portal_results.sh"
REPORTING_SCRIPT_TMP="/tmp/send_report_portal_results.sh"

echo "Downloading send_report_portal_results.sh from ${REPORTING_SCRIPT_URL}"
curl -f -s -o "${REPORTING_SCRIPT_TMP}" "${REPORTING_SCRIPT_URL}"
echo "Successfully downloaded send_report_portal_results.sh, sourcing it..."
# shellcheck source=/dev/null
source "${REPORTING_SCRIPT_TMP}"
rm -f "${REPORTING_SCRIPT_TMP}"

export REPORT_PORTAL_HOSTNAME="reportportal-ossm.apps.dno.ocp-hub.prod.psi.redhat.com"
export REPORT_PORTAL_PROJECT="osssm_general"
export DATA_ROUTER_URL="https://datarouter.ccitredhat.com"

# upload results to report portal
export VERBOSE=true
export TESTRUN_NAME="${TEST_SUITE} test run"
JOB_URL=$(get_job_url)
export TESTRUN_DESCRIPTION="Automated ${TEST_SUITE} test run ${JOB_URL}"
# we have to use SHARED_DIR to be able to get results generated in the previous test step
export TEST_RESULTS_DIR="${SHARED_DIR}"
export PRODUCT_VERSION="${product_version}"
export PRODUCT_STAGE="midstream"
export EXTRA_ATTRIBUTES="[{\"key\": \"ocp_cluster_arch\", \"value\": \"${ocp_arch}\"}, {\"key\": \"ocp_version\", \"value\": \"${ocp_version}\"}, {\"key\": \"trigger\", \"value\": \"ci\"}, {\"key\": \"build_type\", \"value\": \"pr_build\"}]"

validate_environment
set_defaults
send_results
