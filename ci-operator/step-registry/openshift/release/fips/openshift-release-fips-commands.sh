#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${RELEASE_IMAGE_LATEST}" == *"@sha256"* ]]; then
    echo "digest based pullspecs is not supported"
    exit 1
fi

# Get major.minor from payload url
major_minor=$(echo "${RELEASE_IMAGE_LATEST}" | awk -F':' '{print $2}' | awk -F'.' '{print $1"."$2}')

./check-payload scan payload -V "$major_minor" --url "${RELEASE_IMAGE_LATEST}"
