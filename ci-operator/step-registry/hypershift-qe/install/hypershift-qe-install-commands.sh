#!/bin/bash

set -xeuo pipefail
BUCKETNAME="hypershiftqe$RANDOM"

bucket_name_file="${SHARED_DIR}/bucket_name"
echo $BUCKETNAME > "$bucket_name_file"

function export-credentials() {
    platform="$1"
    if [ "$platform" == 'Azure' ]; then
        clientId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_client_id"|base64decode}}')
        clientSecret=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_client_secret"|base64decode}}')
        subscriptionId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_subscription_id"|base64decode}}')
        tenantId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_tenant_id"|base64decode}}')
        echo -e "subscriptionId: $subscriptionId\ntenantId: $tenantId\nclientId: $clientId\nclientSecret: $clientSecret" > "$SHARED_DIR/azurecredentials"
    elif [ "$platform" == "AWS" ]; then
        accessKeyID=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_access_key_id"|base64decode}}')
        secureKey=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_secret_access_key"|base64decode}}')
        echo -e "[default]\naws_access_key_id=$accessKeyID\naws_secret_access_key=$secureKey" > "$SHARED_DIR/awscredentials"
        export AWS_ACCESS_KEY_ID="$accessKeyID"
        export AWS_SECRET_ACCESS_KEY="$secureKey"
    fi
}

which hypershift
platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
export-credentials "$platform"
echo "platform: $platform"
if [ "$platform" == 'Azure' ]; then
    hypershift install \
        --hypershift-image "quay.io/hypershift/hypershift-operator:latest"
elif [ "$platform" == "AWS" ]; then
    region=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
    export AWS_DEFAULT_REGION="$region"
    aws s3api head-bucket --bucket hypershift-qe --region "$region"
    if [ $? -eq 0 ] ; then
        echo "this bucket already exists"
    else
        if [ X"${region}" == X"us-east-1" ]; then
            aws s3api create-bucket --acl public-read --bucket "$BUCKETNAME" \
                --region "$region"
        else
            aws s3api create-bucket --acl public-read --bucket "$BUCKETNAME" \
                --create-bucket-configuration LocationConstraint="$region" \
                --region "$region"
        fi
    fi
fi