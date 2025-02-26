#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

quads_pwd=$(cat "/secret/quads_pwd")

# Login to get token
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Get available hosts for self scheduling
HOST_OUTPUT=$(curl -sSk $QUADS_INSTANCE/api/v3/available\?can_self_schedule\=true)
HOST=$(echo $HOST_OUTPUT | jq -r '.[0]')

# Create self scheduling assignment
CLOUD=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description": "Temporary allocation from openshift-ci", "owner": "metal-perfscale-cpt", "qinq": 1, "wipe": "true"}' $QUADS_INSTANCE/api/v3/assignments/self | jq -r .'cloud.name')

# Create schedule
curl -k -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"cloud\": \"$CLOUD\", \"hostname\": \"$HOST\"}" $QUADS_INSTANCE/api/v3/schedules | jq .'assignment_id' > ${SHARED_DIR}/assignment_id

# Wait for validation to be completed
while [[ $(curl -sSk $QUADS_INSTANCE/api/v3/assignments/63 | jq -r .validated) != "true" ]]; do
  echo "Waiting for validation"
  sleep 15s
done
