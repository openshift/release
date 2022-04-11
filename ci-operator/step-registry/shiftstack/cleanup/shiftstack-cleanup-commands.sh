#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

export OPENSHIFT_INSTALLER="timeout 900 openshift-install"
./clean-ci-resources.sh -o "${ARTIFACT_DIR}/result.json" --delete-everything-older-than-5-hours
