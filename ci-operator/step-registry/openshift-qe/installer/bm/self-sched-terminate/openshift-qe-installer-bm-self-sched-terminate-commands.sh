#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

quads_pwd=$(cat "${CLUSTER_PROFILE_DIR}/quads_pwd")
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})

# Login to get token
echo
echo "Login to get token ..."
TOKEN=$(curl -fsSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Terminate assignment
echo
echo "Terminate assignment ..."
ASSIGNMENT_ID=$(cat "${SHARED_DIR}/assignment_id")
echo "The assignment_id is: $ASSIGNMENT_ID"

TERMINATION_OUTPUT=$(curl -fk -X POST -H "Authorization: Bearer $TOKEN" $QUADS_INSTANCE/api/v3/assignments/terminate/$ASSIGNMENT_ID)
echo $TERMINATION_OUTPUT
