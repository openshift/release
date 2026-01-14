#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create the Jira configuration file
firewatch jira-config-gen --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}" --server-url "${FIREWATCH_JIRA_SERVER}"

report_command="firewatch report"

# If the user has specified verbose test failure reporting
if [ "${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING,,}" = "true" ]; then
    report_command+=" --verbose-test-failure-reporting"
    report_command+=" --verbose-test-failure-reporting-ticket-limit ${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING_LIMIT}"
fi

# If the user specified a configuration file path/url
if [ -n "${FIREWATCH_CONFIG_FILE_PATH}" ]; then
    report_command+=" --firewatch-config-path=${FIREWATCH_CONFIG_FILE_PATH}"
fi

# If the additional labels file exists, add it to the report command
if [ -f "${SHARED_DIR}/${FIREWATCH_JIRA_ADDITIONAL_LABELS_FILE}" ]; then
    report_command+=" --additional-labels-file=${SHARED_DIR}/${FIREWATCH_JIRA_ADDITIONAL_LABELS_FILE}"
fi

echo $report_command

export JOB_NAME=periodic-ci-RedHatQE-interop-testing-master-cnv-odf-ocp-4.21-lp-interop-cr-cnv-component-readiness-aws-ipi-ocp421
export JOB_NAME_SAFE=cnv-component-readiness-aws-ipi-ocp421

build_ids=(1996957998496354304 1997139035914506240 1997320231906709504 1997501458555080704 1997682624558010368 1997863820621516800 1998045059588558848 1998226388703776768 1998407464810188800 1998588648953483264 1998769863740362752 1998950876072382464 1999132068969189376 1999313265116581888 1999494461352054784 1999675657365229568 1999856852904448000)

for id in "${build_ids[@]}"
do
    echo "------------------------------------------"
    echo "Processing Build ID: $id"
    export BUILD_ID=$id
    eval "$report_command"
done
