#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export REGISTRY_AUTH_FILE=/var/secrets/registry-pull-secret/.dockerconfigjson

mkdir -p /tmp/oci-images
skopeo copy --remove-signatures docker://"$SCAN_IMAGE" oci:/tmp/oci-images:image:latest

umoci raw unpack --rootless --image /tmp/oci-images:image:latest /tmp/unpacked-image

/check-payload scan local --path=/tmp/unpacked-image --output-file="$ARTIFACT_DIR"/check-payload-report.txt
