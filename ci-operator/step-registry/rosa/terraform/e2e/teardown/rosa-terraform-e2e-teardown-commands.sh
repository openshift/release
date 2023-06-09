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

EXIT_STATUS=0

GATEWAY_URL="$(echo "${TF_VARS}" | grep 'url' | awk -F '=' '{print $2}' | sed 's/[ |"]//g')"
export GATEWAY_URL

export ARCHIVE_NAME=cluster-terraform-archive
export TF_FOLDER="${TF_FOLDER:-ci/e2e/terraform_provider_ocm_files}"
make destroy_folder || EXIT_STATUS=$?

export ARCHIVE_NAME=account-roles-terraform-archive
export TF_FOLDER=./ci/e2e/account_roles_files/
make destroy_folder || EXIT_STATUS=$?

exit ${EXIT_STATUS}
