#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Source the env.sh file in the shared directory
source ${SHARED_DIR}/env.sh

# Print env varaibles
env

#Print the APPS_URL to verify passing the variable worked
echo $APPS_URL