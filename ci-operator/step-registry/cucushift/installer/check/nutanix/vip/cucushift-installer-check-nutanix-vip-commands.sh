#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/nutanix_context.sh"

check_result=0

# Check ingressVIP works well
console_server=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
if [[ $(dig +short "$console_server") == "$INGRESS_VIP" ]]; then
    echo "Pass: check ingressVIP works well"
else
    echo "Fail: check ingressVIP works well"
    check_result=$((check_result + 1))
fi

# Check apiVIP works well
api_server_url=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}')
api_server=$(echo "$api_server_url" | awk -F[/:] '{print $4}')
if [[ $(dig +short "$api_server") == "$API_VIP" ]]; then
    echo "Pass: check apiVIP works well"
else
    echo "Fail: check apiVIP works well"
    check_result=$((check_result + 1))
fi

exit "${check_result}"
