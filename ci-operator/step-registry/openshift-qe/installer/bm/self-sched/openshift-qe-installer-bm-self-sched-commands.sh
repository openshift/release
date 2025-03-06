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
echo
echo "Login to get token ..."
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Get available hosts for self scheduling from a certain hardware model
echo
echo "Fail if there are not enough hosts ..."
NUM_AVAILABLE=$(curl -sSk $QUADS_INSTANCE/api/v3/available\?can_self_schedule\=true\&model=$MODEL | jq .[] | wc -l)
if [ "$NUM_SERVERS" -gt "$NUM_AVAILABLE" ]; then
  exit 1
else
  echo "Get available hosts for self scheduling from a certain hardware model ..."
  HOSTS=$(curl -sSk $QUADS_INSTANCE/api/v3/available\?can_self_schedule\=true\&model=$MODEL | jq .[0:$NUM_SERVERS] | jq -r .[])
  echo $HOSTS
fi

# [Optional] Get a free VLAN
if [[ $PUBLIC_VLAN == "true" ]]; then
  echo
  echo "Checking for free VLANs ..."
  VLAN_ID=$(curl -sSk $QUADS_INSTANCE/api/v3/vlans/free | jq .[0].'vlan_id')
  echo "The VLAN id is: $VLAN_ID"
  if [[ $VLAN_ID == "null" ]]; then
    echo "No free VLANs available"
    exit 1
  fi
fi

# Create self scheduling assignment
echo
echo "Create self scheduling assignment ..."
if [ -z "${VLAN_ID}" ]; then
  CLOUD_OUTPUT=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description": "Temporary allocation from openshift-ci", "owner": "metal-perfscale-cpt", "qinq": 1, "wipe": "true"}' $QUADS_INSTANCE/api/v3/assignments/self)
else
  CLOUD_OUTPUT=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description": "Temporary allocation from openshift-ci", "owner": "metal-perfscale-cpt", "qinq": 1, "vlan": "'"$VLAN_ID"'", "wipe": "true"}' $QUADS_INSTANCE/api/v3/assignments/self)
fi
echo $CLOUD_OUTPUT | jq .
CLOUD=$(echo $CLOUD_OUTPUT | jq -r .'cloud.name')
echo "The cloud name is: $CLOUD"

# Create schedule
echo
echo "Create schedule ..."

for i in $HOSTS; do
  echo
  echo "Requesting allocation of host $i ..."
  ASSIGNMENT_OUTPUT=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"cloud\": \"$CLOUD\", \"hostname\": \"$i\"}" $QUADS_INSTANCE/api/v3/schedules)
  echo $ASSIGNMENT_OUTPUT | jq .
done
ASSIGNMENT_ID=$(echo $ASSIGNMENT_OUTPUT | jq -r .'assignment_id')
echo
echo "The assignment_id is: $ASSIGNMENT_ID"
echo $ASSIGNMENT_ID > ${SHARED_DIR}/assignment_id

# Wait for validation to be completed
set -x
while [[ $(curl -sSk $QUADS_INSTANCE/api/v3/assignments/$ASSIGNMENT_ID | jq -r .validated) != "true" ]]; do
  echo
  echo "Waiting for validation ..."
  sleep 60s
done
