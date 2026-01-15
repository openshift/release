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

build_ids=(2004205701206904832 2004386898453204992 2004568093967257600 2004749290785738752 2004930487121874944 2005111683822915584 2005292880402321408 2005474077149499392 2005655273582104576 2005836469486227456 2006017665281298432 2006198861244141568 2006380057148264448 2006561235612471296 2006742432435146752 2006923629182324736 2007105219460075520 2007286021292560384 2007467217490284544 2007648413297938432)

for id in "${build_ids[@]}"
do
    echo "------------------------------------------"
    echo "Processing Build ID: $id"
    export BUILD_ID=$id
    eval "$report_command"
done
