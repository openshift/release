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

# Find openshift_version by channel_group in case openshift_version = "" 
ver=$(echo "${TF_VARS}" | grep 'openshift_version' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
if [[ "$ver" == "" ]]; then
    TF_VARS=$(echo "${TF_VARS}" | sed 's/openshift_version.*//')

    chn=$(echo "${TF_VARS}" | grep 'channel_group' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
    if [[ "$chn" == "" ]]; then
        chn='stable'
    fi

    ver=$(curl -kLs https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$chn/release.txt | grep "Name\:" | awk '{print $NF}')
    TF_VARS+=$(echo -e "\nopenshift_version = \"$ver\"")
fi

export TF_VARS

GATEWAY_URL=$(echo "${TF_VARS}" | grep 'url' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
export GATEWAY_URL

export TF_FOLDER_SAVE="${TF_FOLDER:-ci/e2e/terraform_provider_ocm_files}"

export ARCHIVE_NAME=account-roles-terraform-archive
export TF_FOLDER=ci/e2e/account_roles_files
make apply_folder

# TODO: fix this problem or add here a busy-wait loop that makes sure that the account roles exist
echo "As a temporary hack, wait a minute for the account roles to get created..."
sleep 1m

export ARCHIVE_NAME=cluster-terraform-archive
export TF_FOLDER="${TF_FOLDER_SAVE}"
make apply_folder
