#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

quads_pwd=$(cat "/secret/quads_pwd")
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})

# Login to get token
echo
echo "Login to get token ..."
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Terminate assignment
echo
echo "Terminate assignment ..."
ASSIGNMENT_ID=$(cat "${SHARED_DIR}/assignment_id")

TERMINATION_OUTPUT=$(curl -k -X POST -H "Authorization: Bearer $TOKEN" $QUADS_INSTANCE/api/v3/assignments/terminate/$ASSIGNMENT_ID)
echo $TERMINATION_OUTPUT