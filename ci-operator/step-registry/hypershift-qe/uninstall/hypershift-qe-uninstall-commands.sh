#!/bin/bash

set -xeuo pipefail

BUCKETNAME=$(cat "${SHARED_DIR}/bucket_name")
echo "$BUCKETNAME"

hypershift install render --format=yaml | oc delete -f -

platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
if [ "$platform" == "AWS" ]; then
    if [ ! -d config  ];then
        mkdir config
    fi
    accessKeyID=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_access_key_id"|base64decode}}')
    secureKey=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_secret_access_key"|base64decode}}')
    echo -e "[default]\naws_access_key_id=$accessKeyID\naws_secret_access_key=$secureKey" > config/awscredentials
    cp -f "config/awscredentials" "$HOME/.aws/credentials"
    region=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
    aws s3api delete-bucket --bucket "$BUCKETNAME" --region "$region"
fi