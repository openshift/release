#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# --force: the e2e tests may have left PVCs / PVs behind, delete the AWS resources anyway.
/usr/bin/volume-create s3 delete --kubeconfig "${KUBECONFIG}" --local-aws-creds=true --force
echo "Deleted S3 Files resources"
