#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf devscripts ipstack command ************"

echo "export IP_STACK='${IP_STACK}'" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"