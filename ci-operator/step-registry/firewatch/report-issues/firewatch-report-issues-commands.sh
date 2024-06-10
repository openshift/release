#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create the Jira configuration file
firewatch jira-config-gen --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}" --server-url "${FIREWATCH_JIRA_SERVER}"

report_command="firewatch report"

# If the user has specified to fail with test failures, then add the --fail-with-test-failures flag
if [ "${FIREWATCH_FAIL_WITH_TEST_FAILURES,,}" = "true" ]; then
    report_command+=" --fail-with-test-failures"
fi

# If the user has specified verbose test failure reporting
if [ "${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING,,}" = "true" ]; then
    report_command+=" --verbose-test-failure-reporting"
    report_command+=" --verbose-test-failure-reporting-ticket-limit ${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING_LIMIT}"
fi

# If the user specified a platform to use in a basic configuration file
if [[ -z "${FIREWATCH_CONFIG_PLATFORM}" ]]; then
    if [[ "${FIREWATCH_CONFIG_PLATFORM,,}" == "aws" ]]; then
        report_command+=" --firewatch-config-path=https://raw.githubusercontent.com/oharan2/cspi-utils/firewatch_base_configs/firewatch-base-configs/lp-interop-aws-ipi-base-config.json"
    fi
fi

echo $report_command
eval "$report_command"
