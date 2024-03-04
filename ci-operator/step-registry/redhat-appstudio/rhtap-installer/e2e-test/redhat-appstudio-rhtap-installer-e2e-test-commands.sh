#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -x

E2E_FOLDER="${HOME}/rhtap-e2e"

git clone https://github.com/flacatus/rhtap-e2e.git "$E2E_FOLDER"
cd "$E2E_FOLDER"
yarn && yarn test