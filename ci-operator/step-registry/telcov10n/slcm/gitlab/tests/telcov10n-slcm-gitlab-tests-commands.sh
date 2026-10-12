#!/bin/bash

set -e
set -o pipefail

CREDENTIALS_PATH=/var/run/stage-01
CI_PROJECT_ID=`cat $CREDENTIALS_PATH/ci-project-id/CI_PROJECT_ID`
DCI_REMOTE_CI=`cat $CREDENTIALS_PATH/dci-remote-ci/DCI_REMOTE_CI`
ECO_VALIDATION_CONTAINER=`cat $CREDENTIALS_PATH/eco-validation-container/ECO_VALIDATION_CONTAINER`
GITLAB_TOKEN=`cat $CREDENTIALS_PATH/gitlab-token/GITLAB_TOKEN`
GITLAB_URL=`cat $CREDENTIALS_PATH/gitlab-url/GITLAB_URL`
GITLAB_API_TOKEN=`cat $CREDENTIALS_PATH/gitlab-api-token/GITLAB_API_TOKEN`

echo "Start"
echo "SITE_NAME $SITE_NAME"
echo "GITLAB_BRANCH $GITLAB_BRANCH"

# TRIGGER PIPELINE
#

response=$(curl -X POST \
     -s \
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
     $GITLAB_URL/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline)

echo "response:"
echo $response

PIPELINE_ID=$(echo $response | jq -r '.id')

echo "PIPELINE_ID:"
echo $PIPELINE_ID

sleep 5

# POLLING LOOP FOR PIPELINE STATUS
#

# URL of the API endpoint
API_URL="$GITLAB_URL/api/v4/projects/$CI_PROJECT_ID/pipelines/$PIPELINE_ID"

# Function to check the status field in the JSON response
check_status() {
  response=$(curl -s --header "PRIVATE-TOKEN:$GITLAB_API_TOKEN" $API_URL)
  status=$(echo $response | jq -r '.status')

  echo "Status: $status"

  if [[ "$status" == "success" || "$status" == "failed" ]]; then
    # Exit the loop if status is success or failure
    return 0
  else
    # Continue the loop otherwise
    return 1
  fi
}

# Maximum number of retries (18 hours)
MAX_RETRIES=6480

# Initialize retry counter
retry_count=0

# Loop until the status is success or failed, or until retries are exhausted
while [[ "$retry_count" -lt  "$MAX_RETRIES" ]]; do
  if check_status; then
    echo "Exiting loop. Status is $status."
    break
  else
    echo "Status is not success or failed, checking again..."
    retry_count=$((retry_count + 1))
    echo "Retry count: $retry_count/$MAX_RETRIES"
    # Wait for 10 seconds before making the next API call
    sleep 10
  fi
done

return_code=0

if [[ "$retry_count" -eq "$MAX_RETRIES" ]]; then
  echo "Maximum retries reached. Exiting loop."
  return_code=1
fi

if [[ "$status" == "failed" ]]; then
  echo "Pipeline failed."
  return_code=1
fi

if [[ "$status" == "success" ]]; then
  echo "Pipeline success."
fi

exit $return_code
