#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

bastion=$(cat "/secret/address")
PWD=$(cat "/secret/quads_pwd")

# Login to get token
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$PWD" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq .'auth_token')

# Get available hosts for self scheduling
HOST=$(curl -sSk $QUADS_INSTANCE/api/v3/available\?can_self_schedule\=true | jq '.[0]')

# Create self scheduling assignment
CLOUD=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description": "Temporary allocation from openshift-ci", "owner": "metal-perfscale-cpt", "qinq": 1, "wipe": "true"}' $QUADS_INSTANCE/api/v3/assignments/self | jq .'Cloud.Name')

# Create schedule
curl -k -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{'cloud':$CLOUD, 'hostname': $HOST}" $QUADS_INSTANCE/api/v3/schedules | jq .'assignment_id' > ${SHARED_DIR}/assignment_id

# TODO: Wait for validation to be completed
sleep 600