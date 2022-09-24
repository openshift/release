#!/bin/bash

set -euo pipefail

BUCKETNAME=$(cat "${SHARED_DIR}/bucket_name")
echo "$BUCKETNAME"
platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
echo "$platform"

hypershift install render --format=yaml | oc delete -f -

if [ "$platform" == "AWS" ]; then
    accessKeyID=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_access_key_id"|base64decode}}')
    secureKey=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_secret_access_key"|base64decode}}')
    region=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
    export AWS_ACCESS_KEY_ID="$accessKeyID"
    export AWS_SECRET_ACCESS_KEY="$secureKey"
    export AWS_DEFAULT_REGION="$region"
    aws s3api delete-bucket --bucket "$BUCKETNAME" --region "$region"
fi