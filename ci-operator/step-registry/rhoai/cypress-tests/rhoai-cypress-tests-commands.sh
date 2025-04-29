#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
cd odh-dashboard && npm install && npm run build

npm run test
