#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

quads_pwd=$(cat "/secret/quads_pwd")

if [[ $LAB == "performancelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu3.labs.perfscale.redhat.com"
elif [[ $LAB == "scalelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu2.scalelab.redhat.com"
elif [[ $LAB == "scalelab-stage" ]]; then
  export QUADS_INSTANCE="https://quads2-stage.rdu2.scalelab.redhat.com"
fi

# Login to get token
set +x
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Get available hosts for self scheduling from a certain hardware model
echo
echo "Get available hosts for self scheduling from a certain hardware model ..."
HOST_OUTPUT=$(curl -sSk $QUADS_INSTANCE/api/v3/available\?can_self_schedule\=true\&model=$MODEL)
echo $HOST_OUTPUT
HOST=$(echo $HOST_OUTPUT | jq -r '.[0]')
echo $HOST

# Create self scheduling assignment
echo
echo "Create self scheduling assignment ..."
CLOUD_OUTPUT=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description": "Temporary allocation from openshift-ci", "owner": "metal-perfscale-cpt", "qinq": 1, "wipe": "true"}' $QUADS_INSTANCE/api/v3/assignments/self)
echo $CLOUD_OUTPUT
CLOUD=$(echo $CLOUD_OUTPUT | jq -r .'cloud.name')
echo $CLOUD

# Create schedule
echo
echo "Create schedule ..."
ASSIGNMENT_OUTPUT=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"cloud\": \"$CLOUD\", \"hostname\": \"$HOST\"}" $QUADS_INSTANCE/api/v3/schedules)
echo $ASSIGNMENT_OUTPUT
echo $ASSIGNMENT_OUTPUT | jq .'assignment_id' > ${SHARED_DIR}/assignment_id

# Wait for validation to be completed
set -x
while [[ $(curl -sSk $QUADS_INSTANCE/api/v3/assignments/63 | jq -r .validated) != "true" ]]; do
  echo "Waiting for validation ..."
  sleep 60s
done
