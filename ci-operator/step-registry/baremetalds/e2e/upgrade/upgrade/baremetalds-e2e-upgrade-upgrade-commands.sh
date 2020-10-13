#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

openshift-tests run-upgrade --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" --dry-run all