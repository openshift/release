#!/bin/bash

set -e
set -o pipefail

CREDENTIALS_PATH=/var/run/stage-01
CI_PROJECT_ID=`cat $CREDENTIALS_PATH/ci-project-id/CI_PROJECT_ID`
DCI_REMOTE_CI=`cat $CREDENTIALS_PATH/dci-remote-ci/DCI_REMOTE_CI`
ECO_VALIDATION_CONTAINER=`cat $CREDENTIALS_PATH/eco-validation-container/ECO_VALIDATION_CONTAINER`
GITLAB_TOKEN=`cat $CREDENTIALS_PATH/gitlab-token/GITLAB_TOKEN`
GITLAB_URL=`cat $CREDENTIALS_PATH/gitlab-url/GITLAB_URL`

echo "Start"
echo "SITE_NAME $SITE_NAME"
echo "GITLAB_BRANCH $GITLAB_BRANCH"

curl -X POST \
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
     $GITLAB_URL/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline
