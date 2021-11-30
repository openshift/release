#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f ./functions.sh ]; then
  echo "functions.sh file was found, copying it to ${SHARED_DIR}/functions.sh"
  cp ./functions.sh "${SHARED_DIR}/shiftstack-ci-functions.sh"
else
  echo "Warning: unable to find functions.sh script."
  CO_DIR=$(mktemp -d)
  echo "Falling back to local copy in ${CO_DIR}"
  # TODO(emilien): remove the branch override once the PR is merged:
  # https://github.com/shiftstack/shiftstack-ci/pull/172
  git clone -b nfv-common https://github.com/shiftstack/shiftstack-ci.git "${CO_DIR}"
  if [ -f "${CO_DIR}/functions.sh" ]; then
    cp "${CO_DIR}/functions.sh" "${SHARED_DIR}/shiftstack-ci-functions.sh"
  else
    echo "Unable to find functions.sh script in ${CO_DIR}"
  fi
fi
