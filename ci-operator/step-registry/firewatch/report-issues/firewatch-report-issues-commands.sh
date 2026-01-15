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

build_ids=(2000038048204591104 2000219244234543104 2000400461055660032 2000581637368188928 2000762833813377024 2000944045647466496 2001125226011693056 2001306422230388736 2001668875011231744 2001850071259287552 2002031314152198144 2002212508869332992 2002393705071251456 2002574900946014208 2002756097005326336 2002937293995773952 2003118490071863296 2003299686630297600 2003480882756718592 2003662078564372480 2003843273927430144 2004024505185341440)

for id in "${build_ids[@]}"
do
    echo "------------------------------------------"
    echo "Processing Build ID: $id"
    export BUILD_ID=$id
    eval "$report_command"
done
