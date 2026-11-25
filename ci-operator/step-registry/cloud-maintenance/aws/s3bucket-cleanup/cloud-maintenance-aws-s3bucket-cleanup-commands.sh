#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set varaibles needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws

KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
export AWS_ACCESS_KEY_ID=$KEY_ID
export AWS_SECRET_ACCESS_KEY=$ACCESS_KEY

# Remove any spaces from the exclude list
EXCLUDE_LIST=$(echo "$EXCLUDE_LIST" | tr -d ' ')

# Convert the exclude list to an array using a comma as the delimiter
exclude_array=()
if [ -n "$EXCLUDE_LIST" ]; then
    IFS=',' read -ra exclude_array <<< "$EXCLUDE_LIST"
fi

# Set the cutoff time
cutoff=$(date -d "-$BUCKET_AGE_HOURS hours" +%s)

# Get a list of all S3 buckets and their creation dates
buckets=$(aws s3api list-buckets --query "Buckets[*].{Name:Name,Created:CreationDate}" --output text)

# Loop through the list of buckets
while read -r bucket; do
    name=$(echo "$bucket" | awk '{print $2}')
    created=$(echo "$bucket" | awk '{print $1}')
    created_ts=$(date -d "$created" +%s)

    # Check if the bucket is in the exclude list
    excluded=false
    for exclude in "${exclude_array[@]:-}"; do
        if [[ "$name" == "$exclude" ]]; then
            echo "Skipping excluded bucket: $name"
            excluded=true
            break
        fi
    done
    if $excluded; then
        continue
    fi

    # Check if the bucket is older than the cutoff time
    if [ "$created_ts" -lt "$cutoff" ]; then
        # Delete the bucket
        echo "Deleting bucket: $name"
        aws s3 rb "s3://$name" --force
    fi
done <<< "$buckets"
