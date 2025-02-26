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
echo $TOKEN

ASSIGNMENT_ID=$(cat "${SHARED_DIR}/assignment_id")
echo $ASSIGNMENT_ID

curl -k -X POST -H "Authorization: Bearer $TOKEN" $QUADS_INSTANCE/api/v3/assignments/terminate/$ASSIGNMENT_ID