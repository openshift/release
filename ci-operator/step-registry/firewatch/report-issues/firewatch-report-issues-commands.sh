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

build_ids=(1996414251467542528 1996595447770124288 1996776643972042752)

for id in "${build_ids[@]}"
do
    echo "------------------------------------------"
    echo "Processing Build ID: $id"
    export BUILD_ID=$id
    eval "$report_command"
done
