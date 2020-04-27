#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "$#" -ne 1 ]]; then
  echo "You must enter the version to upgrade, e.g., quay.io/openshift-release-dev/ocp-release:4.4.0-rc.12-x86_64"
  exit 1
fi

CHOSEN_VERSION=$1
readonly CHOSEN_VERSION

CHOSEN_IMAGE="$(echo ${CHOSEN_VERSION} | cut -d':' -f1)"
readonly CHOSEN_IMAGE

CHOSEN_TAG="$(echo ${CHOSEN_VERSION} | cut -d':' -f2)"
readonly CHOSEN_TAG

cmd="echo"
if [[ "${DRY_RUN:-}" == "false" ]]; then
  cmd="oc"
fi

IMAGE_DIGEST="$(oc adm release info ${CHOSEN_VERSION} -o json | jq -r '.digest' )"
"${cmd}" --as system:admin --context build01 adm upgrade --allow-explicit-upgrade --to-image "${CHOSEN_IMAGE}@${IMAGE_DIGEST}"
