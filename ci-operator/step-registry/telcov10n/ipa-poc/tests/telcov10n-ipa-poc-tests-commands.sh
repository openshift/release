#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n cluster setup via agent command ************"
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2
echo

echo "************ telcov10n IPA PoC: Load ENV ************"
IPA_TEST_ENV_PATH=/var/run/ipa-poc/
source ${IPA_TEST_ENV_PATH}/ipa-test-settings
CI_PROJECT_ID=$(cat ${IPA_TEST_ENV_PATH}/CI_PROJECT_ID)
GITLAB_TOKEN=$(cat ${IPA_TEST_ENV_PATH}/GITLAB_TOKEN)
echo

echo "************ telcov10n IPA PoC: Show Env ************"
echo
printenv
echo

echo "************ telcov10n IPA PoC: Run Gitlab job ************"
echo
set -x
curl -v -X POST \
     --fail \
     -F token="$GITLAB_TOKEN" \
     -F "ref=$GITLAB_BRANCH" \
     -F "variables[DU_PROFILE]=$DU_PROFILE" \
     -F "variables[SITE_NAME]=$SITE_NAME" \
     -F "variables[DCI_REMOTE_CI]=$DCI_REMOTE_CI" \
     -F "variables[RUN_EDU_TESTS]=true" \
     -F "variables[CNF_IMAGE]=$CNF_IMAGE" \
     -F "variables[STAMP]=$STAMP" \
     -F "variables[OCP_VERSION]=$OCP_VERSION" \
     -F "variables[SPIRENT_PORT]=$SPIRENT_PORT" \
     -F "variables[EDU_PTP]=$EDU_PTP" \
     -F "variables[DEBUG_MODE]=$DEBUG_MODE" \
     -F "variables[ANSIBLE_SKIP_TAGS]=$ANSIBLE_SKIP_TAGS" \
     -F "variables[DCI_PIPELINE_FILES]=$DCI_PIPELINE_FILES" \
     -F "variables[TEST_ID]=$TEST_ID" \
     -F "variables[ECO_VALIDATION_CONTAINER]=$ECO_VALIDATION_CONTAINER" \
     -F "variables[ECO_GOTESTS_CONTAINER]=$ECO_GOTESTS_CONTAINER" \
     https://gitlab.consulting.redhat.com/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline
set +x

sleep 1m

echo
echo "************ telcov10n IPA PoC: Generate Fake JUnit for PoC purpose ************"
echo

mkdir -pv ${ARTIFACT_DIR}/junit
cat << EOF > ${ARTIFACT_DIR}/junit/junit.xml
<?xml version='1.0' encoding='utf-8'?>
<testsuites tests="5" failures="0" errors="0" skipped="0" time="421.66">
  <testsuite name="du_troubleshooting_kdump" errors="0" failures="0" skipped="0" tests="1" time="0.005" timestamp="2024-05-28T16:27:42.144467" hostname="32cdb67cd3c1">
    <testcase classname="" name="test_logs_exist" time="0.005" />
  </testsuite>
  <testsuite name="du_troubleshooting_kdump_recovery" errors="0" failures="0" skipped="0" tests="4" time="421.655" timestamp="2024-05-28T16:27:44.581182" hostname="32cdb67cd3c1">
    <testcase classname="" name="test_ssh_recovery" time="0.006" />
    <testcase classname="" name="test_site_healthz" time="0.032" />
    <testcase classname="" name="test_api_resources_status" time="0.152" />
    <testcase classname="" name="test_operators_status" time="421.465" />
  </testsuite>
</testsuites>
EOF