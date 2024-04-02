#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get major.minor from payload url
major_minor=$(echo "${RELEASE_IMAGE_LATEST}" | awk -F':' '{print $2}' | awk -F'.' '{print $1"."$2}')

./check-payload scan payload -V "$major_minor" --url "${RELEASE_IMAGE_LATEST}"
