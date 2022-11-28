#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Source the env.sh file in the shared directory
source ${SHARED_DIR}/env.sh

secrets_contents=$(ls /tmp/secrets)
echo $secrets_contents

cat /tmp/secrets/ftp-host
cat /tmp/secrets/ftp-username
cat /tmp/secrets/ftp-password

# Update the MTA env file with correct values
if [ -v ${APPS_URL} ]; then
  sed -i 's/REPLACE_OCP_HOSTNAME/http://mta-mta.${APPS_URL}/' $CONFIG_FILE
  sed -i 's/REPLACE_OCP_SECURE_HOSTNAME/https://secure-mta-mta.$(APPS_URL}' $CONFIG_FILE
else
  echo "APPS_URL variable not found"
fi

