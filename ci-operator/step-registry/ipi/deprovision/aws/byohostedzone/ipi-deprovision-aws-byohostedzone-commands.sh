#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

hosted_zone="$(cat "${SHARED_DIR}/byohostedzonename")"
echo "Deleting hostedzone ${hosted_zone}"

aws route53 delete-hostedzone --id "${hosted_zone}"
echo "${hosted_zone} deleted"