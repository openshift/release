#!/bin/bash

set -e
set -o pipefail

CI_PROJECT_ID=`cat /var/run/stage-01/ci-project-id`
DCI_REMOTE_CI=`cat /var/run/stage-01/dci-remote-ci`
ECO_VALIDATION_CONTAINER=`cat /var/run/stage-01/eco-validation-container`
GITLAB_TOKEN=`cat /var/run/stage-01/gitlab-token`
GITLAB_URL=`cat /var/run/stage-01/gitlab-url`

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
