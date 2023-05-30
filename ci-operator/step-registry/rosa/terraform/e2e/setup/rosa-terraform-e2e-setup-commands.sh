#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cp -r /root/terraform-provider-ocm ~/
cd ~/terraform-provider-ocm

export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"
export GOPROXY=https://proxy.golang.org
go mod download
go mod tidy
go mod vendor

TF_VARS=$(cat <<EOF
url = "${GATEWAY_URL}"
openshift_version = "${OPENSHIFT_VERSION}"

EOF
)
export TF_VARS

export ARCHIVE_NAME=account-roles-terraform-archive
export TF_FOLDER=ci/e2e/account_roles_files
make apply_folder

# TODO: fix this problem or add here a busy-wait loop that makes sure that the account roles exist
echo "As a temporary hack, wait a minute for the account roles to get created..."
sleep 1m

export ARCHIVE_NAME=cluster-terraform-archive
export TF_FOLDER=ci/e2e/terraform_provider_ocm_files
make apply_folder
