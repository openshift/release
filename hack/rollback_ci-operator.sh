#!/bin/bash

# Script to rollback the ci-operator version and mirror the image to QCI

# Function to check required tools
check_requirements() {
    for cmd in oc yq jq; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed. Please install it and try again."
            exit 1
        fi
    done
}

# Function to get the tags of ci-operator from app.ci
get_tags() {
    echo "Fetching tags from app.ci imagestream..."
    oc --context app.ci -n ci get imagestreams ci-operator -o yaml | yq '.status.tags'
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch tags from app.ci."
        exit 1
    fi
}

# Function to extract previous digest
get_previous_digest() {
    # Fetch the tags and extract the second-to-last digest
    echo "Extracting the previous digest..."
    prev_digest=$(oc --context app.ci -n ci get imagestreams ci-operator -o yaml | \
                  yq '.status.tags[] | select(.tag == "latest").items | .[1].image')
    
    if [[ -z "$prev_digest" ]]; then
        echo "Error: Could not retrieve the previous digest. Please check the image tags."
        exit 1
    fi
    
    echo "Previous digest found: $prev_digest"
    echo $prev_digest
}

# Function to validate digest
validate_digest() {
    # Check if the digest starts with 'sha256:' and has a length greater than 3 characters after 'sha256:'
    if [[ $1 != sha256:* || ${#1} -le 7 ]]; then
        echo "Error: Invalid digest. The digest must start with 'sha256:' and have more than 3 characters after that."
        exit 1
    fi
}

# Function to tag the given digest to ci-operator:latest
tag_digest() {
    local digest=$1
    echo "Tagging ci-operator@$digest to ci-operator:latest..."
    oc --context app.ci -n ci tag ci-operator@$digest ci-operator:latest
    if [ $? -ne 0 ]; then
        echo "Error: Failed to tag the digest to ci-operator:latest."
        exit 1
    fi
}

# Function to mirror the ci-operator:latest image to QCI
mirror_image() {
    creds_file="/tmp/registry-push-credentials_ci-image-mirror.c"
    trap cleanup EXIT

    echo "Extracting registry-push credentials..."
    oc --context app.ci extract secret/registry-push-credentials-ci-images-mirror -n ci --to=- --keys .dockerconfigjson | jq > "$creds_file"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to extract registry-push credentials."
        exit 1
    fi

    echo "Starting image mirroring to QCI, this may take some time..."
    oc image mirror --keep-manifest-list --registry-config="$creds_file" --continue-on-error=true --max-per-registry=20 \
    registry.ci.openshift.org/ci/ci-operator:latest quay.io/openshift/ci:ci_ci-operator_latest

    local mirror_status=$?
    if [ $mirror_status -eq 0 ]; then
        echo "Image mirroring completed successfully!"
    else
        echo "Image mirroring failed. Please check the logs for details."
        exit 1
    fi

}

cleanup(){
    # Clean up credentials
    echo "Cleaning up credentials..."
    rm -f "$creds_file"  # Remove the temporary credentials file
}

check_requirements

if [ $# -eq 0 ]; then
    echo "No digest provided. Rolling back to the previous digest."
    prev_digest=$(get_previous_digest)
    tag_digest $prev_digest
else
    validate_digest $1
    echo "Using provided digest: $1"
    tag_digest $1
fi

mirror_image

echo "Rollback and mirror process completed."
