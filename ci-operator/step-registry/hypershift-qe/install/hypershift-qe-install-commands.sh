#!/bin/bash

function export-credentials() {
    PLATFORM="$1"
    if [ "$PLATFORM" == 'Azure' ]; then
        clientId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_client_id"|base64decode}}')
        clientSecret=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_client_secret"|base64decode}}')
        subscriptionId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_subscription_id"|base64decode}}')
        tenantId=$(oc get secret -n kube-system azure-credentials -o template='{{index .data "azure_tenant_id"|base64decode}}')
        echo -e "subscriptionId: $subscriptionId\ntenantId: $tenantId\nclientId: $clientId\nclientSecret: $clientSecret" > config/azurecredentials
    elif [ "$PLATFORM" == "AWS" ]; then
        accessKeyID=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_access_key_id"|base64decode}}')
        secureKey=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_secret_access_key"|base64decode}}')
        echo -e "[default]\naws_access_key_id=$accessKeyID\naws_secret_access_key=$secureKey" > config/awscredentials
    fi
}

which hypershift
platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
export-credentials "$platform"
echo "platform: $platform"
if [ "$platform" == 'Azure' ]; then
    bin/hypershift install \
        --hypershift-image "quay.io/hypershift/hypershift-operator:latest"
elif [ "$platform" == "AWS" ]; then
    REGION=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
    cp -f "config/awscredentials" "$HOME/.aws/credentials"

    aws s3api head-bucket --bucket hypershift-qe --region "$REGION"
    if [ $? -eq 0 ] ; then
        echo "this bucket already exists"
    else
        if [ X"${REGION}" == X"us-east-1" ]; then
            aws s3api create-bucket --acl public-read --bucket hypershift-qe \
                --region "$REGION"
        else
            aws s3api create-bucket --acl public-read --bucket hypershift-qe \
                --create-bucket-configuration LocationConstraint="$REGION" \
                --region "$REGION"
        fi
    fi

    bin/hypershift install \
    		--oidc-storage-provider-s3-bucket-name hypershift-qe \
    		--oidc-storage-provider-s3-credentials "config/awscredentials" \
    		--oidc-storage-provider-s3-region "$REGION" \
    		--hypershift-image "quay.io/hypershift/hypershift-operator:latest"
fi