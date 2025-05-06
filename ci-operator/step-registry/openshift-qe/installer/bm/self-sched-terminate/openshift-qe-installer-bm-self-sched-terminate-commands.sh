#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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
echo
echo "Login to get token ..."
TOKEN=$(curl -sSk -X POST -u "metal-perfscale-cpt@redhat.com:$quads_pwd" -H "Content-Type: application/json" $QUADS_INSTANCE/api/v3/login/ | jq -r .'auth_token')

# Terminate assignment
echo
echo "Terminate assignment ..."
ASSIGNMENT_ID=$(cat "${SHARED_DIR}/assignment_id")

TERMINATION_OUTPUT=$(curl -k -X POST -H "Authorization: Bearer $TOKEN" $QUADS_INSTANCE/api/v3/assignments/terminate/$ASSIGNMENT_ID)
echo $TERMINATION_OUTPUT