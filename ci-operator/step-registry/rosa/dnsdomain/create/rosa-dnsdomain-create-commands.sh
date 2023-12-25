#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

output=$(mktemp)
rosa create dnsdomain | tee $output 
grep -oE "[0-9A-Za-z]{4}\.[0-9A-Za-z\.]+{4}" ${output} > "${SHARED_DIR}/rosa_dns_domain"

dns_domain=$(head -n 1 "${SHARED_DIR}/rosa_dns_domain")

if [[ ${dns_domain} == "" ]]; then
  echo "Error: Failed to create dns domain"
  exit 1
fi

echo "DNS domain: $dns_domain"

