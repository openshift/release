#!/bin/bash

set -o nounset

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
E2E_INPUT_DIR="${SHARED_DIR}"
E2E_WAFV2_WEB_ACL_NAME="echoserver-acl-${UNIQUE_HASH}"

echo "=> configuring aws"
if [ -f "${AWSCRED}" ]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"; exit 1
fi

if [ -f "${E2E_INPUT_DIR}/wafv2-webacl" ]; then
    E2E_WAFV2_WEB_ACL_ARN="$(cat ${E2E_INPUT_DIR}/wafv2-webacl)"
    E2E_WAFV2_WEB_ACL_ID="${E2E_WAFV2_WEB_ACL_ARN##*/}"
    echo "=> getting lock token for e2e wafv2 web acl named ${E2E_WAFV2_WEB_ACL_NAME} with id ${E2E_WAFV2_WEB_ACL_ID}"
    LOCK_TOKEN=$(aws wafv2 get-web-acl --name "${E2E_WAFV2_WEB_ACL_NAME}" --id "${E2E_WAFV2_WEB_ACL_ID}" --scope=REGIONAL --output json | jq -r .LockToken)
    if [ -n "${LOCK_TOKEN}" ]; then
        echo "=> deleting e2e wafv2 web acl named ${E2E_WAFV2_WEB_ACL_NAME} with id ${E2E_WAFV2_WEB_ACL_ID}"
        aws wafv2 delete-web-acl --name "${E2E_WAFV2_WEB_ACL_NAME}" --id "${E2E_WAFV2_WEB_ACL_ID}" --scope=REGIONAL --lock-token "${LOCK_TOKEN}"
    fi
else
    echo "=> nothing to do for e2e wafv2 web acl"
fi

if [ -f "${E2E_INPUT_DIR}/waf-webacl" ]; then
    # it's possible to create webacls with duplicate name using wafregional,
    # we have to take this case into account
    for id in $(cat "${E2E_INPUT_DIR}/waf-webacl"); do
        echo "=> getting change token for e2e wafregional web acl: ${id}"
        CHANGE_TOKEN=$(aws waf-regional get-change-token --output json | jq -r .ChangeToken)
        if [ -n "${CHANGE_TOKEN}" ]; then
            echo "=> deleting e2e wafregional web acl: ${id}"
            aws waf-regional delete-web-acl --web-acl-id "${id}" --change-token "${CHANGE_TOKEN}" || true
        fi
    done
else
    echo "=> nothing to do for e2e wafregional web acl"
fi
