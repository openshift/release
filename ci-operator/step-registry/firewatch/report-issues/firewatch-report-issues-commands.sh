#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create the Jira configuration file
firewatch jira_config_gen --token_path "${FIREWATCH_JIRA_API_TOKEN_PATH}" --server_url "${FIREWATCH_JIRA_SERVER}"

if [ "$FIREWATCH_FAIL_WITH_TEST_FAILURES" = "true" ]; then
    firewatch report --fail_with_test_failures
else
    firewatch report
fi

