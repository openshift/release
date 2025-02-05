#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

PWD=$(cat "/secret/quads_pwd")

# Login to get token
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$PWD" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq .'auth_token')

ASSIGNMENT_ID=$(cat "${SHARED_DIR}/assignment_id")

curl -k -X POST -H "Authorization: Bearer $TOKEN" http://quads2-stage.rdu2.scalelab.redhat.com/api/v3/assignments/terminate/$ASSIGNMENT_ID